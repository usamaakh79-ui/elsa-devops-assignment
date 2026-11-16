#!/usr/bin/env bash
# Runs every task in order. Safe to re-run.
#   docker compose up -d && ./scripts/run-all.sh
set -euo pipefail
source "$(dirname "$0")/lib.sh"

if [ -f /tmp/bootstrap.failed ]; then
  log "Previous bootstrap failed - retrying it"
fi
# 00 takes a lock, so if the entrypoint is still bootstrapping we simply wait for it.
for s in 00-bootstrap.sh 20-deploy.sh 25-reclaim-drill.sh 30-troubleshoot.sh; do
  printf '\n\033[1;35m################ %s ################\033[0m\n' "$s"
  bash "$WORKSPACE/scripts/$s"
done

log "All done"
echo "  curl http://localhost:${HOST_HTTP_PORT:-8080}/api/quote"
