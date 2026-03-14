#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------
# Load runtime (privilege guarantees)
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
VENV_ACTIVATE="${PROJECT_BASE_DIR}/.venv/bin/activate"
SUP_CONF="$BENCH_DIR/config/supervisor.conf"
NGINX_CONF="$BENCH_DIR/config/nginx.conf"
REDIS_CONF_DIR="$BENCH_DIR/config"

# -------------------------------------------------
# Logging
# -------------------------------------------------

LOG_FILE=""

if [ -d "$PROJECT_BASE_DIR" ]; then
  mkdir -p "$PROJECT_LOGS_DIR"

  LOG_FILE="$PROJECT_LOGS_DIR/verify_production.log"

  if [ ! -f "$LOG_FILE" ]; then
    touch "$LOG_FILE"
  fi

  exec > >(tee -a "$LOG_FILE") 2>&1
else
  echo "WARN: Project base directory not present yet: $PROJECT_BASE_DIR"
  echo "WARN: Logging to file disabled until project base exists"
fi

echo "== Verifying Frappe production environment =="
echo "Timestamp: $(date -Is)"
echo "Node: $(hostname)"
echo ""

# -------------------------------------------------
# Node specifications
# -------------------------------------------------
echo ">> Node specifications"

echo "Hostname: $(hostname)"
echo "Uptime: $(uptime -p)"
echo "Kernel: $(uname -r)"
echo "OS:"
lsb_release -ds 2>/dev/null || cat /etc/os-release | grep PRETTY_NAME || true

echo ""
echo "CPU:"
lscpu | grep -E 'Model name|Socket|Thread|Core|CPU\(s\)' || true

echo ""
echo "Memory:"
free -h

echo ""
echo "Swap:"
swapon --show || echo "No swap configured"

echo ""
echo "Disk usage:"
df -hT /

# -------------------------------------------------
# Project directory inspection
# -------------------------------------------------
echo ""
echo ">> Project directory inspection"

if [ -d "$PROJECT_BASE_DIR" ]; then
  echo "INFO: Project base directory exists: $PROJECT_BASE_DIR"
  ls -ld "$PROJECT_BASE_DIR"
else
  echo "WARN: Project base directory missing (expected during early node stage)"
fi

echo ""

if [ -d "$PROJECT_BASE_DIR" ]; then
  echo "Top-level project contents:"
  ls -lah "$PROJECT_BASE_DIR"
else
  echo "WARN: Cannot list project contents because directory does not exist"
fi
# -------------------------------------------------
# Ownership & permissions
# -------------------------------------------------
echo ""
echo ">> Ownership & permissions"

check_path() {
  local path="$1"
  if [ -e "$path" ]; then
    stat -c "INFO: %n → owner=%U group=%G perms=%a" "$path"
  else
    echo "WARN: $path missing"
  fi
}

check_path "$PROJECT_BASE_DIR"
check_path "$PROJECT_BASE_DIR/.venv"
check_path "$BENCH_DIR"
check_path "$BENCH_DIR/apps"
check_path "$BENCH_DIR/sites"
check_path "$BENCH_DIR/config"

# -------------------------------------------------
# Bench directory structure (depth=2)
# -------------------------------------------------
echo ""
echo ">> Bench directory structure (depth 2)"

if [ -d "$BENCH_DIR" ]; then
  find "$BENCH_DIR" -maxdepth 2 -type d -print | sed 's/^/DIR: /'
else
  echo "ERROR: Bench directory missing"
fi

# -------------------------------------------------
# Critical file ownership checks
# -------------------------------------------------
echo ""
echo ">> Critical file ownership"

CRITICAL_FILES=(
  "$BENCH_DIR/config/supervisor.conf"
  "$BENCH_DIR/config/nginx.conf"
  "$PROJECT_BASE_DIR/.venv/bin/bench"
)

for f in "${CRITICAL_FILES[@]}"; do
  if [ -f "$f" ]; then
    stat -c "INFO: %n → owner=%U group=%G perms=%a" "$f"
  else
    echo "WARN: Missing critical file: $f"
  fi
done


# -------------------------------------------------
# System services
# -------------------------------------------------
echo ">> System services status"

for svc in nginx supervisor; do
  if systemctl is-active --quiet "$svc"; then
    echo "INFO: $svc is running"
  else
    echo "ERROR: $svc is NOT running"
  fi
done

echo ""

# -------------------------------------------------
# Supervisor control plane
# -------------------------------------------------
echo ">> Supervisor control plane"

if [ -S /var/run/supervisor.sock ]; then
  echo "INFO: supervisor socket exists"
else
  echo "ERROR: supervisor socket missing"
fi

if supervisorctl pid >/dev/null 2>&1; then
  echo "INFO: supervisorctl communication OK"
else
  echo "ERROR: supervisorctl cannot communicate with supervisord"
fi

echo ""

# -------------------------------------------------
# Bench + virtualenv integrity
# -------------------------------------------------
echo ">> Bench & virtualenv integrity"

if [ -f "$VENV_ACTIVATE" ]; then
  echo "INFO: virtualenv present"
else
  echo "ERROR: virtualenv missing at $VENV_ACTIVATE"
fi

if [ -d "$BENCH_DIR" ]; then
  echo "INFO: bench directory present"
else
  echo "ERROR: bench directory missing"
fi

echo ""

# -------------------------------------------------
# Bench configuration files
# -------------------------------------------------
echo ">> Bench configuration files"

for f in \
  "$SUP_CONF" \
  "$NGINX_CONF" \
  "$REDIS_CONF_DIR/redis_queue.conf" \
  "$REDIS_CONF_DIR/redis_cache.conf"
do
  if [ -f "$f" ]; then
    echo "INFO: Found $(basename "$f")"
  else
    echo "WARN: Missing $(basename "$f")"
  fi
done

echo ""

# -------------------------------------------------
# Redis runtime verification (from config)
# -------------------------------------------------
echo ">> Redis runtime verification"

CONFIG_FILE="$BENCH_DIR/sites/common_site_config.json"

if [ -f "$CONFIG_FILE" ]; then
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
      echo "INFO: Redis listening on port $PORT"
    else
      echo "ERROR: Redis NOT listening on port $PORT"
    fi
  done
else
  echo "WARN: common_site_config.json missing — cannot derive Redis ports"
fi

echo ""

# -------------------------------------------------
# Supervisor-managed groups & processes (group-based)
# -------------------------------------------------
echo ">> Supervisor-managed processes (by group)"

# Groups expected at node level (must exist)
NODE_GROUPS=(
  bench-redis
  bench-web
)

# Groups expected at site level (may not exist yet)
SITE_GROUPS=(
  bench-workers
)

inspect_group() {
  local group="$1"

  if supervisorctl status "${group}:*" >/dev/null 2>&1; then
    supervisorctl status "${group}:*" | while read -r line; do
      case "$line" in
        *RUNNING*)
          echo "INFO: $line"
          ;;
        *FATAL*|*EXITED*)
          echo "WARN: $line"
          ;;
        *)
          echo "INFO: $line"
          ;;
      esac
    done
  else
    echo "WARN: Supervisor group '$group' not available or has no processes"
  fi
}

# Inspect node-level groups
for group in "${NODE_GROUPS[@]}"; do
  inspect_group "$group"
done

# Inspect site-level groups
for group in "${SITE_GROUPS[@]}"; do
  inspect_group "$group"
done

echo ""


# -------------------------------------------------
# Gunicorn / socket / port inspection (informational)
# -------------------------------------------------
echo ">> Gunicorn / web listeners"

if ss -tulpn | grep -q gunicorn; then
  ss -tulpn | grep gunicorn | sed 's/^/INFO: /'
else
  echo "WARN: No gunicorn listeners detected (acceptable if no site exists)"
fi

echo ""

# -------------------------------------------------
# Nginx bench server block inspection
# -------------------------------------------------
echo ">> Nginx bench server blocks"

# Syntax check (still useful, but informational)
if nginx -t >/dev/null 2>&1; then
  echo "INFO: nginx configuration syntax is valid"
else
  echo "ERROR: nginx configuration syntax is INVALID"
fi

echo ""

# Locate bench-generated nginx configs
NGINX_SITES_DIR="/etc/nginx/conf.d"
BENCH_NGINX_CONF="$BENCH_DIR/config/nginx.conf"

# -------------------------------------------------
# Bench-generated nginx config (block-aware inspection)
# -------------------------------------------------
echo ">> Bench nginx configuration (generated by bench)"

if [ -f "$BENCH_NGINX_CONF" ]; then
  echo "INFO: Bench nginx config found"

  # File metadata
  stat -c "INFO: Path=%n | Owner=%U | Group=%G | Perms=%a | Modified=%y" \
    "$BENCH_NGINX_CONF"

  echo ""

  # -------------------------------
  # Upstream blocks
  # -------------------------------
  echo "INFO: Nginx upstream blocks (bench-generated)"

  awk '
    $1 == "upstream" {in_block=1}
    in_block {print}
    in_block && /}/ {in_block=0; print ""}
  ' "$BENCH_NGINX_CONF" \
  | sed 's/^/  /' \
  || echo "  WARN: No upstream blocks found"

  echo ""

  # -------------------------------
  # Server blocks
  # -------------------------------
  echo "INFO: Nginx server blocks (bench-generated)"

  awk '
    $1 == "server" && $2 == "{" {in_block=1}
    in_block {print}
    in_block && /}/ {in_block=0; print ""}
  ' "$BENCH_NGINX_CONF" \
  | sed 's/^/  /' \
  || echo "  WARN: No server blocks found"

else
  echo "WARN: Bench nginx config missing at $BENCH_NGINX_CONF"
fi

echo ""


# Active nginx server blocks referencing this bench
echo ">> Active nginx server blocks for this bench"

FOUND=0

for f in "$NGINX_SITES_DIR"/*.conf; do
  if [ -f "$f" ] && grep -q "$BENCH_DIR" "$f"; then
    FOUND=1
    echo "INFO: Server block file: $f"
    echo "----- BEGIN $f -----"
    cat "$f" | sed 's/^/  /' "$f"
    echo "----- END $f -----"
    echo ""
  fi
done

if [ "$FOUND" -eq 0 ]; then
  echo "WARN: No active nginx server blocks found for this bench"
fi

echo ""

echo "== Production verification completed =="
