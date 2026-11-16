# Part 7 — Ops answers

## 1. EKS 1.33 → 1.35 with zero downtime

EKS upgrades the control plane **one minor at a time**, so this is two passes: 1.33 → 1.34 → 1.35.

**Before:** read both release notes for removed APIs/feature gates; scan manifests + Helm releases (`kubent`/`pluto`,
EKS *Upgrade insights*); confirm every addon/controller (vpc-cni, CoreDNS, kube-proxy, EBS/EFS CSI, Karpenter, LB
controller, ArgoCD, cert-manager) has a version compatible with **both** the current and target minor; check PDBs
won't block drains (no `maxUnavailable: 0`, no single-replica PDBs); rehearse on staging; snapshot EBS-backed state.

**Order, per minor:**
1. **Control plane** (`aws eks update-cluster-version`) — AWS rolls the API servers behind the endpoint; kubelets may
   lag the control plane, so nodes keep working.
2. **Addons**: vpc-cni first (pod networking), then kube-proxy, CoreDNS, then EBS/EFS CSI — each to the version the
   EKS compatibility matrix lists for the new minor, `--resolve-conflicts PRESERVE` so custom config survives.
3. **Data plane**: managed nodegroups via rolling update / Karpenter by bumping the AMI alias (drift replaces nodes
   respecting PDBs and disruption budgets). Spot pools first, then on-demand, GPU last (longest warm-up, expensive
   to churn). Watch error budgets between waves.
4. Repeat for the second minor; then remove deprecated API usage you found earlier.

**Top 3 risks:** (1) **Removed/changed APIs or feature behaviours** breaking Helm/ArgoCD syncs mid-upgrade → caught
by the pre-scan and staging. (2) **Addon/controller incompatibility** — an old vpc-cni or CSI driver means pods
without IPs or volumes that won't attach → upgrade addons immediately after the control plane, before nodes.
(3) **Drains that stall or cause outages** — over-tight PDBs block rollouts; too-loose ones (or singletons) cause
downtime; GPU workloads with long startup lose capacity → right-size PDBs, surge capacity before draining, and
upgrade node pools in small batches.

## 2. Spot reclaims paging at 3 AM

The alert is answering the wrong question. "A node is unreachable" is *expected* for spot; what matters is
"**are users affected**" and "**is capacity failing to come back**".

- **Page only on symptoms (SLOs):** multi-window, multi-burn-rate alerts on error rate/latency per service
  (e.g. 14× burn over 5m *and* 1h). A healthy spot reclaim never burns budget → never pages.
- **Make node alerts reclaim-aware:** the AWS Node Termination Handler / Karpenter marks interrupted nodes (taint +
  event from the 2-minute interruption notice / EventBridge). Inhibit `KubeNodeUnreachable` for nodes that received
  an interruption notice or carry `karpenter.sh/capacity-type=spot` and are being disrupted (Alertmanager
  `inhibit_rules`, or `unless on(node)` in the expression). Send spot reclaims to a **ticket/Slack** channel as info.
- **Keep real node failures:** still alert (page) when (a) an **on-demand/GPU** node is NotReady > 5m without an
  interruption signal, (b) **NotReady nodes > N% of a pool** or a pool can't be replenished (`Pending` pods >10m,
  Karpenter `NodeClaim` launch failures / `InsufficientCapacity`), (c) any workload's ready replicas < its PDB
  `minAvailable` for >5m. Add `for:` durations so a 30s reclaim-and-replace never fires.
- **Group and dedupe** by `cluster, nodepool` so one event is one notification, not 40.

Net effect: a reclaim that the platform heals produces no page; a reclaim that *isn't* healed (no replacement
capacity, user-facing errors) pages within minutes.

## 3. Cloudflare in front, mobile LCP 5s — is HTML cached?

1. **Measure where the time goes**: PageSpeed/CrUX field data vs lab; in WebPageTest/DevTools look at **TTFB** of the
   HTML document. If TTFB is ~1–2 s+, it's the origin path (caching); if TTFB is low, it's render (images, JS, fonts).
2. **Headers on the HTML** (`curl -sI https://site/ -H 'User-Agent: <mobile UA>'`, repeated a few times, from 2 regions):
   - `cf-cache-status`: `DYNAMIC` = not eligible (Cloudflare **does not cache HTML by default**); `MISS` every time =
     cacheable but evicted/varied; `BYPASS` = a rule or a cookie bypasses it; `HIT` = fine → look elsewhere.
   - `cache-control` from origin: `private`, `no-store`, `max-age=0` disable it; `set-cookie` on HTML (session /
     analytics / A-B cookies) makes it uncacheable; `vary: user-agent` or `vary: cookie` fragments the cache —
     classic cause for *mobile-only* misses.
   - `age`, `cf-ray` (which PoP) to confirm repeated requests hit the same colo.
3. **Rules**: check Cache Rules / legacy Page Rules order — is there a rule making HTML "Eligible for cache" with an
   Edge TTL? Is a broader rule (`/*` bypass, "bypass on cookie") overriding it? Are query strings (utm, fbclid)
   making every URL unique (cache key → ignore marketing params)? Any Workers or APO config in the path? Device-type
   cache key splitting?
4. **Origin**: if it truly must render per request, measure origin TTFB directly (`curl -w '%{time_starttransfer}'`
   with `--resolve` to bypass CF): slow app/DB, no origin keep-alive, far-away region. Fix: cache rule for HTML with
   Edge TTL + `stale-while-revalidate`, strip cookies on anonymous pages, origin `Cache-Control: public, s-maxage=…`,
   purge-on-publish from the CMS; enable Tiered Cache.
5. **Then the non-cache LCP fixes**: LCP image preloaded/`fetchpriority=high`, responsive AVIF/WebP, no lazy-load on
   the hero, defer render-blocking JS/CSS, early hints. Verify with field data over 28 days, not one lab run.

## 4. Application secrets on EKS

**A. External Secrets Operator (ESO) + AWS Secrets Manager / SSM Parameter Store.** Secrets live in AWS; ESO (auth
via **EKS Pod Identity/IRSA**, per-namespace `SecretStore` scoped to a path prefix) syncs them into native K8s
Secrets on an interval. Apps consume plain env/volumes; rotation happens in AWS; Git holds only `ExternalSecret`
references (GitOps-friendly). Cost: secrets exist as K8s Secrets in etcd (mitigate with EKS envelope encryption via
KMS + tight RBAC).

**B. Sealed Secrets / SOPS (encrypted secrets in Git).** Ciphertext committed to the repo, decrypted in-cluster.
Simple, no cloud dependency, everything in Git. But: key management per cluster (sealed for one cluster's key won't
open on another), rotation means re-encrypting and committing, no central audit of *who read what*, and revoking
access to a leaked ciphertext is impossible — it's in Git history forever.

**Pick for a startup with multiple prod EKS clusters: A (ESO + Secrets Manager).** One source of truth across
clusters, IAM-scoped access with CloudTrail audit, rotation without commits, and onboarding a new cluster is
"install ESO + grant the role" instead of re-sealing everything. Use the **Secrets Store CSI driver** instead only
for workloads that must never have a K8s Secret object. Guardrails: KMS envelope encryption on, no `get secrets`
RBAC for humans in prod, ESO `refreshInterval` ~1h with apps reloading on change (Reloader).
