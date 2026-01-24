#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------
# Load runtime (privilege + user guarantees)
# -------------------------------------------------
: "${SCRIPT_LIB_DIR:?}"

RUNTIME_SH="${SCRIPT_LIB_DIR}/runtime.sh"
[ -f "$RUNTIME_SH" ] || { echo "runtime.sh not found"; exit 1; }

# shellcheck source=/dev/null
source "$RUNTIME_SH"

require_root

# -------------------------------------------------
# Required environment variables
# -------------------------------------------------
: "${PROJECT_BASE_DIR:?}"
: "${PROJECT_LOGS_DIR:?}"

BENCH_DIR="${PROJECT_BASE_DIR}/bench"

[ -d "$BENCH_DIR" ] || { echo "Bench directory missing"; exit 1; }

# -------------------------------------------------
# Logging (root-owned)
# -------------------------------------------------
exec > >(tee -a "$PROJECT_LOGS_DIR/stop_services.log") 2>&1

echo "== Stopping production services for this bench =="

# -------------------------------------------------
# Supervisor control-plane sanity
# -------------------------------------------------
if [ ! -S /var/run/supervisor.sock ]; then
  echo "Supervisor socket not present — nothing to stop"
  exit 0
fi

if ! supervisorctl pid >/dev/null 2>&1; then
  echo "Supervisor not responding — nothing to stop"
  exit 0
fi

echo ">> Supervisor control plane is healthy"

# -------------------------------------------------
# Stop Supervisor-managed services (GROUP-BASED)
# -------------------------------------------------
echo ">> Stopping Supervisor-managed services for this bench"

# Node-level groups (always safe to stop)
NODE_GROUPS=(
  bench-web
  bench-redis
)

for group in "${NODE_GROUPS[@]}"; do
  if supervisorctl stop "${group}:*"; then
    echo ">> Stopped Supervisor group: $group"
  else
    echo "WARN: Supervisor group '$group' may already be stopped"
  fi
done

# Site-level group (may or may not exist)
SITE_GROUPS=(
  bench-workers
)

for group in "${SITE_GROUPS[@]}"; do
  if supervisorctl stop "${group}:*"; then
    echo ">> Stopped Supervisor group: $group"
  else
    echo "WARN: Supervisor group '$group' not stopped (may not exist yet)"
  fi
done

# -------------------------------------------------
# Reload Nginx (do NOT stop)
# -------------------------------------------------
if systemctl is-active --quiet nginx; then
  echo ">> Reloading nginx"
  systemctl reload nginx || echo "WARN: nginx reload failed"
else
  echo "nginx not running — skipping reload"
fi

echo "== Bench production services stopped safely =="
