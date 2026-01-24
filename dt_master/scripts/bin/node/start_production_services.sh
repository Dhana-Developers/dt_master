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

ENV_FILE="${PROJECT_BASE_DIR}/.venv/bin/activate"
[ -f "$ENV_FILE" ] || { echo "Virtualenv activate file missing"; exit 1; }

# -------------------------------------------------
# Logging (root-owned)
# -------------------------------------------------
exec > >(tee -a "$PROJECT_LOGS_DIR/start_services.log") 2>&1

echo "== Starting production services =="

# -------------------------------------------------
# Supervisor control-plane sanity (NOT process health)
# -------------------------------------------------
if [ ! -S /var/run/supervisor.sock ]; then
  echo "ERROR: Supervisor socket missing"
  exit 1
fi

if ! supervisorctl pid >/dev/null 2>&1; then
  echo "ERROR: supervisorctl cannot communicate with supervisord"
  exit 1
fi

echo ">> Supervisor control plane is healthy"

# -------------------------------------------------
# Reload Supervisor configuration
# -------------------------------------------------
echo ">> Reloading Supervisor configuration"
supervisorctl reread
supervisorctl update

# -------------------------------------------------
# Start Supervisor-managed services
# -------------------------------------------------
echo ">> Starting Supervisor-managed services"

# --- Node-level groups (HARD REQUIREMENT) ---
NODE_GROUPS=(
  bench-redis
  bench-web
)

for group in "${NODE_GROUPS[@]}"; do
  if supervisorctl start "${group}:*"; then
    echo ">> Started Supervisor group: $group"
  else
    echo "ERROR: Failed to start required Supervisor group: $group"
    exit 1
  fi
done

# --- Site-level group (SOFT REQUIREMENT) ---
SITE_GROUPS=(
  bench-workers
)

for group in "${SITE_GROUPS[@]}"; do
  if supervisorctl start "${group}:*"; then
    echo ">> Started Supervisor group: $group"
  else
    echo "WARN: Supervisor group '$group' not started (likely no site exists yet)"
  fi
done

# -------------------------------------------------
# Reload Nginx (safe)
# -------------------------------------------------
echo ">> Reloading Nginx"
systemctl reload nginx

echo "== Production services start sequence complete =="
