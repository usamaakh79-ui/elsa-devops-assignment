#!/usr/bin/env bash
# Part 3: apply the provided broken manifests, show the symptoms, apply
# troubleshoot/fixed-app.yaml and run the provided verify.sh (must print PASS).
# Idempotent: re-running replays broken -> fixed -> verify.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

TS="$WORKSPACE/troubleshoot"

log "Applying the provided broken manifests (as instructed)"
kubectl apply -f "$TS/broken-app.yaml"
sleep 20

log "Symptoms"
kubectl -n troubleshoot get pods -o wide || true
kubectl -n troubleshoot get endpoints web-svc 2>/dev/null || true
kubectl -n troubleshoot get events --sort-by=.lastTimestamp 2>/dev/null \
  | grep -E 'Failed|FailedScheduling|FailedMount|BackOff|Unhealthy' | tail -n 8 || true

log "Applying troubleshoot/fixed-app.yaml"
kubectl apply -f "$TS/fixed-app.yaml"
kubectl -n troubleshoot rollout status deploy/web --timeout=180s
kubectl -n troubleshoot rollout status deploy/ai-inference --timeout=180s
kubectl -n troubleshoot get pods -o wide

log "Running the provided verifier"
OUT=$(sh "$TS/verify.sh" 2>&1) || { echo "$OUT"; die "verify.sh failed"; }
echo "$OUT"
echo "$OUT" | tail -n 1 | grep -qx PASS || die "verify.sh did not print PASS"
ok "Part 3 PASS"
