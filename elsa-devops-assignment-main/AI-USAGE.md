# AI usage disclosure

## Tools and where they were used

| Tool | Used for |
|---|---|
| **Claude Code** (Anthropic, Claude Opus model, agentic CLI with file + shell access) | Primary tool for everything: reading the brief and provided package, drafting the app, Dockerfiles, compose harness, scripts, Helm chart, ArgoCD app, fixed manifests, GitHub Actions workflow, and first drafts of all docs. It also ran the local checks (unit tests, Semgrep, `bash -n`, YAML parsing). |
| **Semgrep** (not AI, but it's how AI output got checked) | The CI gate doubled as a reviewer of the AI-generated workflow and Dockerfiles — see the examples below. |
| **GitHub Actions `e2e` job** | Runs the Golden Rule on a clean runner, because the machine this was developed on has no local Docker. Anything Claude wrote about cluster behaviour is only trusted once that job is green. |

## Prompts that actually moved things forward

1. *"Here is the assignment and the zip in Downloads — do CORE, pick one of Parts 4–6, and Part 7."* → Claude
   proposed Part 4 because the same pipeline produces the GHCR image the CORE needs and can run the Golden Rule as an
   e2e test — which mattered since there's no local Docker to test on.
2. *"With 3 replicas, prove which placement constraint guarantees ≥1 on on-demand without deadlocking a drain."* →
   led to working through skew arithmetic: `maxSkew: 1` gives 50/50 at scale (too much on-demand); `maxSkew: 2` is
   the largest value that still forces the 3rd replica to on-demand; and `nodeTaintsPolicy: Honor` is what stops a
   cordoned node from pinning the skew calculation during the drill.
3. *"What in the provided files is broken or inconsistent, beyond the obvious Part 3 bugs?"* → surfaced the hard-coded
   AWS keys in the legacy pipeline (redacted), the `node-type` vs `acme.io/node-type` mismatch, `Equal` vs `Exists`
   toleration for the EKS-style taint, and the single-replica Traefik that would make the reclaim drill fail for the
   wrong reason.

## Where the AI was wrong or suboptimal — and how it was caught

1. **Mutable action tags (caught by the gate it wrote).** The first workflow draft used `actions/checkout@v4`.
   Running the Semgrep gate locally *before* the first push failed with `github-actions-mutable-action-tag`. Fix: looked
   up the real tag commits with `git ls-remote` (not from model memory) and pinned `checkout@34e1148… # v4.3.1`,
   `setup-python@a26af69… # v5.6.0`. Also the reason the workflow uses no third-party actions at all.
2. **A "fix" that would have been wrong.** The same scan flagged the toolbox Dockerfile for running as root. The
   reflex fix (add `USER nonroot`) breaks the toolbox: it must use the host Docker socket, whose GID varies per host,
   and socket access is root-equivalent anyway. Decision: keep root, add an inline `# nosemgrep` with the reasoning,
   and document it as a reviewed exception in MIGRATION-NOTES — instead of silencing the rule globally.
3. **Build cache that would not have worked.** The draft used `--cache-to/--cache-from type=gha` in plain `run:` steps.
   That backend needs runtime tokens that GitHub only exposes to JavaScript actions (which is why people use
   `docker/setup-buildx-action`). Caught on review; replaced with reusing the same buildx builder between the scan
   build and the push build.
4. **Unverified tag.** The draft pinned `tonistiigi/binfmt:qemu-v9.2.2` — a tag nobody had checked exists. Switched to
   a known tag (`qemu-v7.0.0`) rather than trusting a plausible-looking version string.
5. **Expected vs observed output.** Error strings in TROUBLESHOOTING.md were first written from how Kubernetes
   *usually* reports each failure, before a cluster existed to run them on. The authoritative output is the
   `30-troubleshoot.sh` step of the CI `e2e` job; any snippet that differs from that log gets corrected, not defended.

## What I own

I can explain and defend every file in a live walkthrough, in particular: the topology-spread arithmetic, why HPA
owns `replicas`, why ArgoCD pulls instead of CI pushing, why the SAST gate has a self-test, and each Part 3 root cause.
