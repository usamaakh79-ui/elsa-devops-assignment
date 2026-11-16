#!/usr/bin/env bash
# Part 2: spot-reclaim drill. Drains a spot node that hosts a quote-api replica
# while a curl loop hits the service through the ingress, shows the pods
# rescheduling, then uncordons. Fails if availability drops below MIN_SUCCESS_PCT.
# Idempotent: any spot node left cordoned by an interrupted run is uncordoned first.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

MIN_SUCCESS_PCT="${MIN_SUCCESS_PCT:-99}"
SEL=app.kubernetes.io/name=quote-api

log "Pre-flight"
for n in $(kubectl get nodes -l acme.io/capacity=spot -o name); do kubectl uncordon "$n" >/dev/null; done
kubectl -n "$APP_NS" rollout status deploy/quote-api --timeout=120s >/dev/null
placement_report

# Prefer a spot node that actually runs a replica - otherwise the drill proves nothing.
VICTIM=""
for node in $(kubectl get nodes -l acme.io/capacity=spot -o jsonpath='{.items[*].metadata.name}'); do
  if kubectl -n "$APP_NS" get pods -l "$SEL" --field-selector "spec.nodeName=$node" --no-headers 2>/dev/null | grep -q .; then
    VICTIM=$node; break
  fi
done
[ -n "$VICTIM" ] || VICTIM=$(kubectl get nodes -l acme.io/capacity=spot -o jsonpath='{.items[0].metadata.name}')

RESULTS=$(mktemp)
cleanup() {
  [ -n "${LOOP_PID:-}" ] && kill "$LOOP_PID" 2>/dev/null || true
  kubectl uncordon "$VICTIM" >/dev/null 2>&1 || true
  rm -f "$RESULTS"
}
trap cleanup EXIT

log "Starting curl loop against $INGRESS_URL/api/quote (5 req/s)"
(
  while true; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$INGRESS_URL/api/quote" || echo 000)
    echo "$(date +%H:%M:%S) $code" >> "$RESULTS"
    sleep 0.2
  done
) &
LOOP_PID=$!
sleep 5

log "Simulating spot reclaim: draining $VICTIM"
kubectl drain "$VICTIM" --ignore-daemonsets --delete-emptydir-data --timeout=180s
ok "$VICTIM drained"

log "Waiting for quote-api to be back at full strength"
kubectl -n "$APP_NS" rollout status deploy/quote-api --timeout=180s
retry 30 2 sh -c "[ \"\$(kubectl -n $APP_NS get deploy quote-api -o jsonpath={.status.readyReplicas})\" = \"\$(kubectl -n $APP_NS get deploy quote-api -o jsonpath={.spec.replicas})\" ]"
kubectl -n "$APP_NS" get pods -l "$SEL" -o wide
placement_report
sleep 5

log "Recent scheduling events"
kubectl -n "$APP_NS" get events --sort-by=.lastTimestamp \
  --field-selector involvedObject.kind=Pod 2>/dev/null | grep -E 'Scheduled|Killing|Started' | tail -n 10 || true

kill "$LOOP_PID" 2>/dev/null || true; wait "$LOOP_PID" 2>/dev/null || true; LOOP_PID=""
TOTAL=$(wc -l < "$RESULTS" | tr -d ' ')
OK_COUNT=$(grep -c ' 200$' "$RESULTS" || true)
PCT=$(( TOTAL > 0 ? OK_COUNT * 100 / TOTAL : 0 ))
log "Availability during the drill: $OK_COUNT/$TOTAL requests OK (${PCT}%)"
grep -v ' 200$' "$RESULTS" | head -n 10 | sed 's/^/  non-200: /' || true

log "Uncordoning $VICTIM (reclaimed capacity comes back)"
kubectl uncordon "$VICTIM"
kubectl get nodes -L acme.io/capacity -L acme.io/node-type

[ "$PCT" -ge "$MIN_SUCCESS_PCT" ] || die "availability ${PCT}% < ${MIN_SUCCESS_PCT}%"
ok "Service survived the reclaim"
