# Part 3 — Troubleshooting log

`troubleshoot/broken-app.yaml` applied as-is on the k3d cluster after `prepare.sh`.
Fixed manifests: [`troubleshoot/fixed-app.yaml`](troubleshoot/fixed-app.yaml) (every change tagged `FIX #n`).
Reproduce end to end: `./scripts/30-troubleshoot.sh` (applies broken → shows symptoms → applies fixed → runs `verify.sh`).

Approach: work from the outside in. First "does the pod exist and get scheduled", then "does the container start",
then "is it Ready", then "does the Service find it", then "can traffic actually flow". Several bugs hide behind each
other, so I re-checked after each fix rather than assuming the list was complete.

The issues below are numbered to match the `FIX #n` tags in the manifest. On a real cluster (k3s v1.31, all
messages below are copied from actual runs) they **surface in a different order**, because each stage blocks the next:

1. `Pending` → memory request (#2): the scheduler rejects the pod, so nothing is pulled or mounted yet.
2. `ContainerCreating` → ConfigMap typo (#4): kubelet mounts volumes *before* pulling the image.
3. `ErrImagePull` → image tag (#1).
4. `Running 0/1` + restarts → probe port (#3).
5. Ready but no endpoints / refused → Service (#5).
6. Smoke test fails → NetworkPolicy (#7). `ai-inference` (#6) is independent and `Pending` from the start.

First look:

```bash
kubectl -n troubleshoot get deploy,rs,pods,svc,endpoints,networkpolicy -o wide
kubectl -n troubleshoot get events --sort-by=.lastTimestamp
kubectl get nodes -L acme.io/capacity -L acme.io/node-type
kubectl describe node <gpu-node> | grep -A2 Taints
```

---

### 1. `web`: image tag does not exist

- **Symptom:** once scheduling and the volume mount are fixed, `web` pods go `ErrImagePull` → `ImagePullBackOff`.
- **Diagnose:**
  ```bash
  kubectl -n troubleshoot describe pod -l app=web | grep -A5 Events
  #   Failed to pull image "nginx:1.25.99": rpc error: code = NotFound desc = failed to pull and unpack image
  #   "docker.io/library/nginx:1.25.99": failed to resolve reference "docker.io/library/nginx:1.25.99": ... not found
  ```
- **Root cause:** `nginx:1.25.99` was never published (1.25.x stops at 1.25.5).
- **Fix:** `nginx:1.25.5` — a real, pinned patch release (not `latest`, so the fix is reproducible).

### 2. `web`: memory request no node can satisfy

- **Symptom:** the very first thing you see: both `web` pods `Pending`.
- **Diagnose:**
  ```bash
  kubectl -n troubleshoot describe pod -l app=web | grep -A3 FailedScheduling
  #   0/5 nodes are available: 1 node(s) had untolerated taint {nvidia.com/gpu: true}, 4 Insufficient memory.
  #   preemption: 0/5 nodes are available: 1 Preemption is not helpful for scheduling, 4 No preemption victims
  kubectl get nodes -o custom-columns=NAME:.metadata.name,MEM:.status.allocatable.memory
  ```
- **Root cause:** `requests.memory: 16Gi` (and limit 16Gi) for a static nginx. The scheduler places on *requests*, and no
  node has 16Gi allocatable. Even on a large node this would waste a whole node's worth of reservable memory.
  Note: k3d nodes are containers and report the **host's** RAM, so on a host with >16Gi free this bug may not show
  up as `Pending` at all. It is still a bug (each replica reserves a whole laptop's memory), so it is fixed regardless.
- **Fix:** `requests.memory: 32Mi`, `limits.memory: 128Mi` (nginx serving one file uses a few MiB).

### 3. `web`: probes point at the wrong port

- **Symptom:** pods are `Running` but `0/1` Ready, and the restart counter climbs every ~15s (liveness kills them).
- **Diagnose:**
  ```bash
  kubectl -n troubleshoot get pods -l app=web
  #   web-...   0/1   Running   3 (3s ago)   50s
  kubectl -n troubleshoot get events | grep -E 'Unhealthy|Killing'
  #   Readiness probe failed: Get "http://10.42.x.y:8080/": dial tcp 10.42.x.y:8080: connect: connection refused
  #   Liveness probe failed: Get "http://10.42.x.y:8080/": dial tcp 10.42.x.y:8080: connect: connection refused
  #   Container nginx failed liveness probe, will be restarted
  kubectl -n troubleshoot exec deploy/web -- grep listen /etc/nginx/conf.d/default.conf
  #   listen       80;
  ```
- **Root cause:** nginx listens on 80; both probes hit 8080.
- **Fix:** named the container port `http` (80) and pointed both probes at `port: http`, so port numbers live in one place.

### 4. `web`: ConfigMap name typo

- **Symptom:** after the memory fix, pods are scheduled but stuck in `ContainerCreating` (this hides the image bug:
  kubelet mounts volumes before it pulls the image).
- **Diagnose:**
  ```bash
  kubectl -n troubleshoot describe pod -l app=web | grep FailedMount
  #   MountVolume.SetUp failed for volume "html" : configmap "web-conf" not found
  kubectl -n troubleshoot get configmap
  #   web-config
  ```
- **Root cause:** volume references `web-conf`; the ConfigMap is `web-config`.
- **Fix:** `configMap.name: web-config`.

### 5. `web-svc`: wrong selector and wrong targetPort

- **Symptom:** Service exists but has no endpoints; once the selector is fixed, connections are refused.
- **Diagnose:**
  ```bash
  kubectl -n troubleshoot get endpoints web-svc          # <none>
  kubectl -n troubleshoot get svc web-svc -o jsonpath='{.spec.selector}'   # {"app":"webapp"}
  kubectl -n troubleshoot get pods --show-labels          # app=web
  # after fixing only the selector:
  kubectl -n troubleshoot get endpoints web-svc          # 10.42.2.10:8080,10.42.4.12:8080  <- wrong port
  #   curl: (7) Failed to connect to web-svc port 80 after 1 ms: Couldn't connect to server
  ```
- **Root cause:** two independent bugs — selector `app: webapp` matches nothing (pods are `app: web`), and
  `targetPort: 8080` while nginx listens on 80.
- **Fix:** `selector: {app: web}`, `targetPort: http`.

### 6. `ai-inference`: never scheduled onto the GPU node

- **Symptom:** `Pending` forever.
- **Diagnose:**
  ```bash
  kubectl -n troubleshoot describe pod -l app=ai-inference | grep -A3 FailedScheduling
  #   0/5 nodes are available: 5 node(s) didn't match Pod's node affinity/selector.
  kubectl get nodes -L node-type -L acme.io/node-type      # only acme.io/node-type is set
  kubectl get node <gpu-node> -o jsonpath='{.spec.taints}'  # nvidia.com/gpu=true:NoSchedule
  # after fixing only the label key, the message changes:
  #   0/5 nodes are available: 1 node(s) had untolerated taint {nvidia.com/gpu: true},
  #   4 node(s) didn't match Pod's node affinity/selector.
  ```
- **Root cause:** two layers. (a) `nodeSelector: node-type: gpu` uses a label key that does not exist — the nodepool
  label is `acme.io/node-type`. (b) After fixing the key, the pod is still rejected because the GPU node is tainted
  `nvidia.com/gpu=true:NoSchedule` and the pod has no toleration. A nodeSelector *attracts*; a taint *repels* — you
  need both to land on a dedicated pool.
- **Fix:** `nodeSelector: {acme.io/node-type: gpu}` + toleration `nvidia.com/gpu` `operator: Exists` `effect: NoSchedule`.
  I used `Exists` rather than `Equal "true"` so the same manifest also works with the value-less
  `nvidia.com/gpu:NoSchedule` taint that EKS GPU nodepools/Karpenter typically set. Node labels and taints untouched.

### 7. NetworkPolicy: default-deny blocks the smoke test (Service + DNS path)

- **Symptom:** with every pod Ready and endpoints present, `verify.sh` step 7 still fails: the smoke job's curl
  fails instantly (k3s' kube-router network-policy controller *rejects* denied packets rather than dropping them, so
  you get "refused", not a timeout).
- **Diagnose:**
  ```bash
  kubectl -n troubleshoot get networkpolicy                # only default-deny (Ingress+Egress, all pods)
  kubectl -n troubleshoot logs job/smoke-test
  #   curl: (7) Failed to connect to web-svc.troubleshoot.svc.cluster.local port 80 after 0 ms: Couldn't connect to server
  kubectl -n troubleshoot get job smoke-test -o jsonpath='{.spec.template.metadata.labels}'  # app=smoke-client
  kubectl -n kube-system get pods -l k8s-app=kube-dns --show-labels
  # test DNS on its own from a pod in a default-deny namespace:
  kubectl -n troubleshoot run d --rm -i --restart=Never --image=busybox:1.36 -- nslookup kubernetes.default
  #   nslookup: write to '10.43.0.10': Connection refused
  ```
  The curl error is identical before and after allowing DNS, so it does not tell you *which* flow is blocked. I
  tested each flow separately (DNS with `nslookup`, then pod→web), which showed three separate denials.
- **Root cause:** `default-deny` denies all ingress *and* egress for every pod in the namespace, and nothing allows the
  three flows the smoke test needs: client → CoreDNS (53), client → web (80), web ← client (80).
- **Fix (kept default-deny, added least privilege):**
  - `web-allow-ingress-from-smoke-client`: pods `app=web` accept TCP/80 only from pods `app=smoke-client`.
  - `smoke-client-allow-egress`: pods `app=smoke-client` may egress only to `app=web` on TCP/80 and to
    `kube-system/k8s-app=kube-dns` on UDP+TCP/53.
  - `ai-inference` gets no allow rules — it needs no network, so it keeps full default-deny.
  - Note the port in the policy is the **pod** port (80), not the Service port: policies are evaluated after the
    Service DNAT. Kubelet probes still work because node→local-pod traffic is allowed by the k3s policy controller.

---

### Result

```
$ ./troubleshoot/verify.sh
[1/7] default-deny NetworkPolicy must still exist ...
...
[7/7] In-cluster smoke test through the Service...

PASS
```
Verified on a local run (k3d, 1 server + 4 agents, k3s v1.31.5).
This output is produced on every CI run by the `e2e` job (GitHub Actions → `ci` → `e2e` → `./scripts/run-all.sh`).

### Provided-file observations ("imperfect handoff")

- The label-key mismatch (`node-type` vs `acme.io/node-type`) is between `broken-app.yaml` and `prepare.sh`; I treated
  `prepare.sh` (the "nodepool" definition) as the source of truth and fixed the workload, as the rules require.
- `prepare.sh` says "run ONCE". My bootstrap re-runs it on every toolbox start; I checked it is idempotent
  (`--overwrite` on label and taint, roles assigned by sorted node name, which is stable for k3d agents), so re-runs
  are no-ops. I did not modify it.
- `verify.sh` reads the core/v1 `Endpoints` API, which is deprecated from Kubernetes 1.33 (EndpointSlices). Pinned
  k3s v1.31 so it runs without warnings; I left the provided script unmodified.
