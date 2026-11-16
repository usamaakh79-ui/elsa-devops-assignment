# shellcheck shell=bash
# Shared helpers, sourced by every numbered script.
#
# Every script works both ways:
#   - on the host:        ./scripts/20-deploy.sh   -> re-executes itself inside the toolbox
#   - inside the toolbox: /workspace/scripts/20-deploy.sh
if [ ! -f /.toolbox ]; then
  cd "$(dirname "$0")/.." || exit 1
  # MSYS_NO_PATHCONV stops Git Bash on Windows rewriting /workspace/... into C:/...
  MSYS_NO_PATHCONV=1 exec docker compose exec -T toolbox bash "/workspace/scripts/$(basename "$0")" "$@"
fi

export WORKSPACE=/workspace
export CLUSTER_NAME="${CLUSTER_NAME:-elsa}"
export KUBECONFIG="${KUBECONFIG:-/root/.kube/config}"
# k3d's load balancer container; reachable from the toolbox once it joins the cluster network.
export INGRESS_URL="http://k3d-${CLUSTER_NAME}-serverlb"
export APP_NS=quote-api

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m  ✔ %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m  ✘ %s\033[0m\n' "$*" >&2; exit 1; }

# retry <attempts> <sleep-seconds> <cmd...>
retry() {
  local n=$1 s=$2 i=1; shift 2
  until "$@"; do
    [ "$i" -ge "$n" ] && return 1
    i=$((i + 1)); sleep "$s"
  done
}

# Print where each quote-api pod runs and assert the Part 2 placement policy:
# all pods on spot/on-demand nodes, at least one on on-demand, none on GPU.
placement_report() {
  local rows od=0 bad=0
  rows=$(kubectl -n "$APP_NS" get pods -l app.kubernetes.io/name=quote-api \
    --field-selector=status.phase=Running -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.nodeName}{"\n"}{end}')
  printf '  %-34s %-22s %s\n' POD NODE CAPACITY
  while read -r pod node; do
    [ -z "$pod" ] && continue
    cap=$(kubectl get node "$node" -o jsonpath='{.metadata.labels.acme\.io/capacity}')
    printf '  %-34s %-22s %s\n' "$pod" "$node" "${cap:-<none>}"
    case "$cap" in on-demand) od=$((od + 1)) ;; spot) ;; *) bad=$((bad + 1)) ;; esac
  done <<< "$rows"
  [ "$bad" -eq 0 ] || die "$bad pod(s) outside the spot/on-demand pools"
  [ "$od" -ge 1 ] || die "no replica on the on-demand node"
  ok "placement OK: $od replica(s) on on-demand, rest on spot, none on GPU/control-plane"
}
