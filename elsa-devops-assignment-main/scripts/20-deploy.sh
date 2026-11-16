#!/usr/bin/env bash
# Part 2: install ArgoCD, register the quote-api Application (Helm chart from
# this Git repo), wait until it is Synced/Healthy and answering through the
# ingress. Idempotent.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

ARGOCD_VERSION="${ARGOCD_VERSION:-v2.14.2}"

log "Installing ArgoCD ${ARGOCD_VERSION}"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f - >/dev/null
# Server-side apply: the ApplicationSet CRD is too large for the client-side
# last-applied-configuration annotation.
kubectl apply --server-side --force-conflicts -n argocd \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml" >/dev/null
kubectl -n argocd rollout status deploy/argocd-repo-server --timeout=300s
kubectl -n argocd rollout status deploy/argocd-server --timeout=300s
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=300s
ok "ArgoCD running"

log "Registering the quote-api Application (GitOps source: $(grep repoURL "$WORKSPACE/deploy/argocd/quote-api.yaml" | awk '{print $2}'))"
kubectl apply -f "$WORKSPACE/deploy/argocd/quote-api.yaml"
# Ask for an immediate refresh instead of waiting for the 3-minute poll.
kubectl -n argocd annotate application quote-api argocd.argoproj.io/refresh=normal --overwrite >/dev/null

log "Waiting for the Application to be Synced + Healthy"
app_state() { kubectl -n argocd get application quote-api -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null; }
if ! retry 60 5 sh -c '[ "$(kubectl -n argocd get application quote-api -o jsonpath={.status.sync.status}/{.status.health.status} 2>/dev/null)" = "Synced/Healthy" ]'; then
  echo "Application state: $(app_state)"
  kubectl -n argocd get application quote-api -o jsonpath='{.status.conditions}{"\n"}{.status.operationState.message}{"\n"}' || true
  kubectl -n "$APP_NS" get pods -o wide || true
  die "quote-api did not become Synced/Healthy"
fi
ok "Application $(app_state)"

log "Placement (expect: spot + on-demand nodes only, >=1 replica on on-demand, none on GPU)"
placement_report

log "Smoke test through the ingress"
retry 30 2 curl -fsS "$INGRESS_URL/api/quote" >/dev/null || die "ingress did not answer"
curl -fsS "$INGRESS_URL/api/quote"; echo
ok "From the host: curl http://localhost:${HOST_HTTP_PORT:-8080}/api/quote"
echo "  ArgoCD status: docker compose exec toolbox kubectl -n argocd get applications"
