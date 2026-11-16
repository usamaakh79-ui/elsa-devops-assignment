#!/usr/bin/env bash
# Create (or restart) the k3d cluster: 1 server + 4 agents, then label/taint the
# nodes with the provided troubleshoot/prepare.sh. Idempotent; runs automatically
# from the toolbox entrypoint on `docker compose up -d`.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

# Entry point and run-all.sh may both call this: serialize them.
exec 9>/tmp/bootstrap.lock
flock 9

AGENTS="${AGENTS:-4}"
K3S_IMAGE="${K3S_IMAGE:-rancher/k3s:v1.31.5-k3s1}"
HOST_HTTP_PORT="${HOST_HTTP_PORT:-8080}"
NET="k3d-${CLUSTER_NAME}"
LB="k3d-${CLUSTER_NAME}-serverlb"

log "Cluster '${CLUSTER_NAME}'"
if k3d cluster get "$CLUSTER_NAME" >/dev/null 2>&1; then
  ok "exists - making sure it is started"
  k3d cluster start "$CLUSTER_NAME" --wait >/dev/null
else
  k3d cluster create "$CLUSTER_NAME" \
    --image "$K3S_IMAGE" \
    --servers 1 --agents "$AGENTS" \
    --port "${HOST_HTTP_PORT}:80@loadbalancer" \
    --k3s-arg "--tls-san=${LB}@server:*" \
    --kubeconfig-update-default=false \
    --wait --timeout 300s
fi

log "Joining toolbox to the cluster network and writing kubeconfig"
docker network connect "$NET" "$(hostname)" 2>/dev/null || true   # already connected is fine
mkdir -p "$(dirname "$KUBECONFIG")"
k3d kubeconfig get "$CLUSTER_NAME" \
  | sed -E "s#server: https://[^ ]+#server: https://${LB}:6443#" > "$KUBECONFIG"
chmod 600 "$KUBECONFIG"
retry 30 2 kubectl get --raw /readyz >/dev/null || die "API server not reachable at ${LB}:6443"
ok "API server reachable"

log "Waiting for $((AGENTS + 1)) nodes to be Ready"
retry 60 3 sh -c "[ \$(kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready ') -ge $((AGENTS + 1)) ]" \
  || die "nodes not Ready"
kubectl wait --for=condition=Ready nodes --all --timeout=120s >/dev/null

log "Simulating production nodepools (troubleshoot/prepare.sh, provided - unmodified)"
sh "$WORKSPACE/troubleshoot/prepare.sh"

log "Making the ingress controller survive a node drain (2 Traefik replicas + PDB)"
# k3s ships a single Traefik replica: draining its node would take the whole
# ingress path down during the reclaim drill, masking what we want to measure.
kubectl apply -f "$WORKSPACE/deploy/cluster/traefik-config.yaml"
retry 60 5 sh -c '[ "$(kubectl -n kube-system get deploy traefik -o jsonpath={.status.readyReplicas} 2>/dev/null)" = "2" ]' \
  || echo "  (traefik not at 2 replicas yet - continuing, helm-controller will converge)"

log "Bootstrap complete"
kubectl get nodes -L acme.io/capacity -L acme.io/node-type
