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
BENCH_DIR="${PROJECT_BASE_DIR}/bench"
BENCH_BIN="${PROJECT_BASE_DIR}/.venv/bin/bench"
FRAPPE_USER="frappe"
CONFIG_FILE="${BENCH_DIR}/sites/common_site_config.json"

[ -f "$ENV_FILE" ] || { echo "$ENV_FILE missing"; exit 1; }
[ -x "$BENCH_BIN" ] || { echo "Bench binary not found at $BENCH_BIN"; exit 1; }
[ -f "$CONFIG_FILE" ] || { echo "Missing common_site_config.json"; exit 1; }

# -------------------------------------------------
# Global lock (node-level)
# -------------------------------------------------
LOCK_FILE="/var/lock/dt_prepare_production_node.lock"
exec 9>"$LOCK_FILE" || exit 1
flock -n 9 || {
  echo "Node production preparation already running — exiting"
  exit 0
}

# -------------------------------------------------
# Logging (root-owned)
# -------------------------------------------------
exec > >(tee -a "$PROJECT_LOGS_DIR/prepare_production_node.log") 2>&1

echo "== Preparing node for production (NODE LEVEL) =="

# -------------------------------------------------
# Ensure Supervisor is installed and running
# -------------------------------------------------
echo ">> Ensuring Supervisor is installed and running"

if ! command -v supervisorctl >/dev/null 2>&1; then
  echo ">> Supervisor not installed — installing"
  apt-get update -y
  apt-get install -y supervisor
fi

# Enable service if needed
if ! systemctl is-enabled supervisor >/dev/null 2>&1; then
  systemctl enable supervisor
fi

# Start service if not running
if ! systemctl is-active supervisor >/dev/null 2>&1; then
  echo ">> Supervisor not running — starting"
  systemctl start supervisor
fi

# -------------------------------------------------
# Final sanity check: supervisor control plane only
# -------------------------------------------------

echo ">> Verifying Supervisor control plane"

# Give supervisor a moment to initialize
sleep 4

if ! systemctl is-active supervisor >/dev/null 2>&1; then
  echo "ERROR: Supervisor service is not active"
  systemctl status supervisor --no-pager || true
  exit 1
fi

if ! supervisorctl status >/dev/null 2>&1; then
  echo "ERROR: supervisorctl cannot communicate with supervisord"
  exit 1
fi

echo ">> Supervisor control plane is healthy"

echo ">> Supervisor process summary:"
supervisorctl status || true

echo ">> Supervisor is installed and running"

# -------------------------------------------------
# Redis setup (bench-level, as frappe)
# -------------------------------------------------
if [ ! -f "$BENCH_DIR/config/redis_queue.conf" ]; then
  echo ">> Setting up Redis configuration"
  run_as_frappe bash -c "
    source '$ENV_FILE'
    cd '$BENCH_DIR'
    bench setup redis
  "
else
  echo ">> Redis already configured"
fi

# -------------------------------------------------
# Supervisor setup (bench config as frappe)
# -------------------------------------------------
if [ ! -f "$BENCH_DIR/config/supervisor.conf" ]; then
  echo ">> Setting up Supervisor configuration"
  run_as_frappe bash -c "
    source '$ENV_FILE'
    cd '$BENCH_DIR'
    bench setup supervisor --yes
  "
else
  echo ">> Supervisor already configured (bench config exists)"
fi

# -------------------------------------------------
# Nginx production setup (requires root)
# -------------------------------------------------
if [ ! -f "$BENCH_DIR/config/nginx.conf" ]; then
  echo ">> Setting up Nginx production config"
  bash -c "
    source '$ENV_FILE'
    cd '$BENCH_DIR'
    bench setup production '$FRAPPE_USER' --yes
  "
else
  echo ">> Nginx already configured"
fi

# -------------------------------------------------
# Reload Supervisor configs
# -------------------------------------------------
echo ">> Reloading Supervisor configuration"
supervisorctl reread
supervisorctl update

# -------------------------------------------------
# Start Supervisor-managed services
# -------------------------------------------------
echo ">> Starting Supervisor-managed services"

# --- Node-level service groups (HARD REQUIREMENT) ---
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

# --- Site-level service group (SOFT REQUIREMENT) ---
SITE_GROUPS=(
  bench-workers
)

for group in "${SITE_GROUPS[@]}"; do
  if supervisorctl start "${group}:*"; then
    echo ">> Started Supervisor group: $group"
  else
    echo "WARN: Supervisor group '$group' not fully started (likely no site exists yet)"
  fi
done

# -------------------------------------------------
# Redis health check (config-driven)
# -------------------------------------------------
echo ">> Verifying Redis endpoints from config"

REDIS_PORTS=$(
  jq -r '
    .redis_cache?,
    .redis_queue?,
    .redis_socketio?
  ' "$CONFIG_FILE" \
  | grep -v null \
  | sed -E 's|.*:([0-9]+)$|\1|' \
  | sort -u
)

for PORT in $REDIS_PORTS; do
  if ss -ltn | awk '{print $4}' | grep -q ":$PORT$"; then
    echo ">> Redis running on port $PORT"
  else
    echo "ERROR: Redis not running on required port $PORT"
    exit 1
  fi
done

# -------------------------------------------------
# Reload Nginx
# -------------------------------------------------
echo ">> Reloading Nginx"
systemctl reload nginx

echo "== Node production preparation complete =="
