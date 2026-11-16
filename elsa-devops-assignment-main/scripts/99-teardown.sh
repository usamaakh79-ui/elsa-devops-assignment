#!/usr/bin/env bash
# Deletes the k3d cluster (its node containers live outside compose).
# Afterwards run `docker compose down` on the host.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

log "Deleting k3d cluster '${CLUSTER_NAME}'"
docker network disconnect "k3d-${CLUSTER_NAME}" "$(hostname)" 2>/dev/null || true
k3d cluster delete "$CLUSTER_NAME"
ok "Cluster deleted. Now run: docker compose down"
