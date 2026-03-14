#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------
# Load runtime (privilege + user guarantees)
# -------------------------------------------------
: "${SCRIPT_LIB_DIR:?}"

RUNTIME_SH="${SCRIPT_LIB_DIR}/runtime.sh"
if [ ! -f "$RUNTIME_SH" ]; then
  echo "ERROR: runtime.sh not found at $RUNTIME_SH"
  exit 1
fi

# shellcheck source=/dev/null
source "$RUNTIME_SH"

require_root

# -------------------------------------------------
# Required environment variables
# -------------------------------------------------
: "${PROJECT_BASE_DIR:?}"
: "${PROJECT_LOGS_DIR:?}"
: "${FRAPPE_VERSION:=0}"

# -------------------------------------------------
# Resolve Frappe branch
# -------------------------------------------------
if [ "$FRAPPE_VERSION" -eq 0 ]; then
  FRAPPE_BRANCH=""
  echo ">> Using latest Frappe version"
else
  FRAPPE_BRANCH="version-${FRAPPE_VERSION}"
  echo ">> Using Frappe branch: $FRAPPE_BRANCH"
fi

# -------------------------------------------------
# Logging
# -------------------------------------------------
exec > >(tee -a "$PROJECT_LOGS_DIR/init_project.log") 2>&1

echo "== Initializing Frappe project =="

VENV_DIR="$PROJECT_BASE_DIR/.venv"
BENCH_DIR="$PROJECT_BASE_DIR/bench"

# -------------------------------------------------
# Python interpreter for Frappe v16
# -------------------------------------------------
FRAPPE_PYTHON="python3.14"

if ! command -v "$FRAPPE_PYTHON" >/dev/null 2>&1; then
  echo "ERROR: $FRAPPE_PYTHON is not installed"
  exit 1
fi

echo ">> Using Python interpreter: $FRAPPE_PYTHON"

# -------------------------------------------------
# Preconditions (system-level)
# -------------------------------------------------
echo ">> Verifying required system dependencies"

command -v git  >/dev/null || { echo "ERROR: git is not installed"; exit 1; }
command -v node >/dev/null || { echo "ERROR: node is not installed"; exit 1; }
command -v npm  >/dev/null || { echo "ERROR: npm is not installed"; exit 1; }
command -v yarn >/dev/null || { echo "ERROR: yarn is not installed"; exit 1; }

command -v wkhtmltopdf >/dev/null || {
  echo "WARNING: wkhtmltopdf not installed (PDF features may fail later)"
}

# -------------------------------------------------
# Ensure Supervisor is NOT running
# -------------------------------------------------
if command -v supervisorctl >/dev/null 2>&1; then
  if pgrep -x supervisord >/dev/null 2>&1; then
    echo ">> Supervisor is running — stopping it before bench init"
    systemctl stop supervisor || systemctl stop supervisord || true
    sleep 2
  fi

  if pgrep -x supervisord >/dev/null 2>&1; then
    echo "ERROR: Supervisor is still running. Cannot continue with bench init."
    exit 1
  fi

  echo ">> Supervisor is not running (safe for bench init)"
fi

# -------------------------------------------------
# Python virtualenv check
# -------------------------------------------------
if ! run_as_frappe test -d "$VENV_DIR"; then
  echo "ERROR: Virtual environment not found at $VENV_DIR"
  exit 1
fi

# -------------------------------------------------
# Idempotency guard
# -------------------------------------------------
if run_as_frappe test -d "$BENCH_DIR"; then
  echo "Bench already initialized at $BENCH_DIR"
  exit 0
fi

# -------------------------------------------------
# Ensure minimum swap (4GB)
# -------------------------------------------------
REQUIRED_SWAP_MB=4096
SWAPFILE="/swapfile"

current_swap_mb=$(free -m | awk '/Swap:/ {print $2}')

if [ "$current_swap_mb" -lt "$REQUIRED_SWAP_MB" ]; then
  echo ">> Swap is ${current_swap_mb}MB, ensuring ${REQUIRED_SWAP_MB}MB"

  if swapon --show | grep -q "$SWAPFILE"; then
    echo ">> Swapfile exists but is too small — recreating"
    swapoff "$SWAPFILE" || true
    rm -f "$SWAPFILE"
  fi

  echo ">> Creating ${REQUIRED_SWAP_MB}MB swapfile at $SWAPFILE"
  fallocate -l "${REQUIRED_SWAP_MB}M" "$SWAPFILE" \
    || dd if=/dev/zero of="$SWAPFILE" bs=1M count="$REQUIRED_SWAP_MB"

  chmod 600 "$SWAPFILE"
  mkswap "$SWAPFILE"
  swapon "$SWAPFILE"

  if ! grep -q "^$SWAPFILE" /etc/fstab; then
    echo "$SWAPFILE none swap sw 0 0" >> /etc/fstab
  fi

  echo ">> Swap configured successfully"
else
  echo ">> Swap is sufficient (${current_swap_mb}MB)"
fi

# -------------------------------------------------
# Node memory cap
# -------------------------------------------------
export NODE_OPTIONS="--max-old-space-size=1024"
echo ">> NODE_OPTIONS set to $NODE_OPTIONS"

# -------------------------------------------------
# Initialize bench
# -------------------------------------------------
echo ">> Running bench init"

run_as_frappe bash -c "
  set -e
  source '$VENV_DIR/bin/activate'
  cd '$PROJECT_BASE_DIR'

  if [ -z '$FRAPPE_BRANCH' ]; then
    bench init bench --python $FRAPPE_PYTHON
  else
    bench init bench --frappe-branch '$FRAPPE_BRANCH' --python $FRAPPE_PYTHON
  fi
"

# -------------------------------------------------
# Post-init sanity check
# -------------------------------------------------
if ! run_as_frappe test -f "$BENCH_DIR/Procfile"; then
  echo "ERROR: Bench initialization incomplete (Procfile missing)"
  exit 1
fi

echo "== Project initialized successfully =="