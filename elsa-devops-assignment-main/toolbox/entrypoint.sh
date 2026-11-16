#!/usr/bin/env bash
# Toolbox entrypoint: bootstrap the cluster as part of `docker compose up -d`,
# then stay alive so the numbered scripts can be exec'd into this container.
# Progress: `docker compose logs -f toolbox`.
set -uo pipefail
rm -f /tmp/bootstrap.done /tmp/bootstrap.failed
if bash /workspace/scripts/00-bootstrap.sh 2>&1 | tee /tmp/bootstrap.log; then
  touch /tmp/bootstrap.done
else
  touch /tmp/bootstrap.failed
  echo "BOOTSTRAP FAILED - see above; fix and re-run ./scripts/00-bootstrap.sh"
fi
exec sleep infinity
