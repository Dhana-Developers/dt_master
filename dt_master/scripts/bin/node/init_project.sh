#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------
# Load runtime
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

# -------------------------------------------------
# Decode framework context (base64)
# -------------------------------------------------
FRAMEWORK_CONTEXT="{}"

if [ -n "${FRAMEWORK_CONTEXT_B64:-}" ]; then
  FRAMEWORK_CONTEXT=$(echo "$FRAMEWORK_CONTEXT_B64" | base64 -d || echo "{}")
fi

# -------------------------------------------------
# Extract runtime values (safe)
# -------------------------------------------------
FRAMEWORK_NAME=""
FRAMEWORK_VERSION=""
PYTHON_VERSION=""

if command -v jq >/dev/null 2>&1; then
  if echo "$FRAMEWORK_CONTEXT" | jq empty >/dev/null 2>&1; then
    FRAMEWORK_NAME=$(echo "$FRAMEWORK_CONTEXT" | jq -r '.framework // empty')
    FRAMEWORK_VERSION=$(echo "$FRAMEWORK_CONTEXT" | jq -r '.version // empty')
    PYTHON_VERSION=$(echo "$FRAMEWORK_CONTEXT" | jq -r '.python_version // empty')
  fi
fi

# Fallbacks
FRAMEWORK_NAME="${FRAMEWORK_NAME:-${FRAMEWORK_NAME:-frappe}}"
FRAMEWORK_VERSION="${FRAMEWORK_VERSION:-${FRAPPE_VERSION:-}}"
PYTHON_VERSION="${PYTHON_VERSION:-${PYTHON_VERSION:-}}"

: "${PYTHON_VERSION:?PYTHON_VERSION is required}"

PYTHON_BIN="python${PYTHON_VERSION}"

echo ">> Framework: $FRAMEWORK_NAME"
echo ">> Version: $FRAMEWORK_VERSION"
echo ">> Python: $PYTHON_BIN"

# -------------------------------------------------
# Resolve branch (framework-aware)
# -------------------------------------------------
FRAPPE_BRANCH=""

if [ "$FRAMEWORK_NAME" = "Frappe" ]; then
  if [ -n "$FRAMEWORK_VERSION" ]; then
    FRAPPE_BRANCH="version-${FRAMEWORK_VERSION}"
    echo ">> Using Frappe branch: $FRAPPE_BRANCH"
  else
    echo ">> Using latest Frappe version"
  fi
fi

# -------------------------------------------------
# Logging
# -------------------------------------------------
exec > >(tee -a "$PROJECT_LOGS_DIR/init_project.log") 2>&1

echo "== Initializing Project =="

VENV_DIR="$PROJECT_BASE_DIR/.venv"
BENCH_DIR="$PROJECT_BASE_DIR/bench"

# -------------------------------------------------
# Validate Python
# -------------------------------------------------
if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
  echo "ERROR: $PYTHON_BIN is not installed"
  exit 1
fi

# -------------------------------------------------
# Preconditions
# -------------------------------------------------
echo ">> Verifying system dependencies"

for cmd in git node npm yarn; do
  command -v "$cmd" >/dev/null || {
    echo "ERROR: $cmd is not installed"
    exit 1
  }
done

if ! command -v wkhtmltopdf >/dev/null 2>&1; then
  echo "WARNING: wkhtmltopdf not installed"
fi

# -------------------------------------------------
# Stop supervisor if running
# -------------------------------------------------
if command -v supervisorctl >/dev/null 2>&1; then
  if pgrep -x supervisord >/dev/null 2>&1; then
    echo ">> Stopping supervisor"
    systemctl stop supervisor || systemctl stop supervisord || true
    sleep 2
  fi
fi

# -------------------------------------------------
# Validate venv
# -------------------------------------------------
if ! run_as_frappe test -d "$VENV_DIR"; then
  echo "ERROR: Virtual environment missing"
  exit 1
fi

# -------------------------------------------------
# Idempotency
# -------------------------------------------------
if run_as_frappe test -d "$BENCH_DIR"; then
  echo ">> Bench already exists"
  exit 0
fi

# -------------------------------------------------
# Ensure swap (smart + non-destructive + precise)
# -------------------------------------------------
REQUIRED_SWAP_MB=4096
TOLERANCE_MB=16
SWAPFILE="/swapfile"

echo ">> Checking swap configuration"

# -------------------------------------------------
# Get active swap info
# -------------------------------------------------
active_swap=$(swapon --show 2>/dev/null | awk 'NR>1 {print $1}')
swapfile_active=false

if echo "$active_swap" | grep -Fxq "$SWAPFILE"; then
  swapfile_active=true
fi

# -------------------------------------------------
# Get swapfile size (accurate, not du)
# -------------------------------------------------
swapfile_size_mb=0
if [ -f "$SWAPFILE" ]; then
  size_bytes=$(stat -c%s "$SWAPFILE")
  swapfile_size_mb=$((size_bytes / 1024 / 1024))
fi

# -------------------------------------------------
# Get total swap (prefer swapon over free)
# -------------------------------------------------
current_swap_mb=$(swapon --show 2>/dev/null | awk 'NR>1 {sum+=$3} END {print int(sum)}')

# fallback if swapon fails
if [ -z "$current_swap_mb" ] || [ "$current_swap_mb" -eq 0 ]; then
  current_swap_mb=$(free -m | awk '/Swap:/ {print $2}')
fi

echo ">> Current total swap: ${current_swap_mb}MB"
echo ">> Swapfile size: ${swapfile_size_mb}MB (active: $swapfile_active)"

# -------------------------------------------------
# Case 1: Swap is already sufficient (with tolerance)
# -------------------------------------------------
if [ "$current_swap_mb" -ge $((REQUIRED_SWAP_MB - TOLERANCE_MB)) ]; then
  echo ">> Swap is sufficient — no changes needed"
  exit 0
fi

echo ">> Swap below required (${REQUIRED_SWAP_MB}MB), evaluating..."

# -------------------------------------------------
# Case 2: Swapfile exists and size is correct (with tolerance)
# -------------------------------------------------
if [ "$swapfile_size_mb" -ge $((REQUIRED_SWAP_MB - TOLERANCE_MB)) ] && \
   [ "$swapfile_size_mb" -le $((REQUIRED_SWAP_MB + TOLERANCE_MB)) ]; then

  if [ "$swapfile_active" = false ]; then
    echo ">> Activating existing swapfile"
    swapon "$SWAPFILE"
  else
    echo ">> Existing swapfile already active and within acceptable range"
  fi

else
  # -------------------------------------------------
  # Case 3: Need to recreate swapfile
  # -------------------------------------------------
  echo ">> Swapfile size incorrect or missing — recreating"

  if [ "$swapfile_active" = true ]; then
    echo ">> Disabling active swapfile"

    if ! swapoff "$SWAPFILE"; then
      echo ">> swapoff failed, forcing swapoff -a"
      swapoff -a || {
        echo "ERROR: Could not disable swap"
        exit 1
      }
    fi
  fi

  if [ -f "$SWAPFILE" ]; then
    echo ">> Removing old swapfile"
    chattr -i "$SWAPFILE" 2>/dev/null || true
    rm -f "$SWAPFILE"
  fi

  echo ">> Creating swapfile (${REQUIRED_SWAP_MB}MB)"

  fallocate -l "${REQUIRED_SWAP_MB}M" "$SWAPFILE" \
    || dd if=/dev/zero of="$SWAPFILE" bs=1M count="$REQUIRED_SWAP_MB"

  chmod 600 "$SWAPFILE"
  mkswap "$SWAPFILE"
  swapon "$SWAPFILE"
fi

# -------------------------------------------------
# Persist in fstab
# -------------------------------------------------
if ! grep -q "^$SWAPFILE " /etc/fstab; then
  echo "$SWAPFILE none swap sw 0 0" >> /etc/fstab
fi

echo ">> Swap ready"

# -------------------------------------------------
# Node memory tuning
# -------------------------------------------------
export NODE_OPTIONS="--max-old-space-size=1024"

# -------------------------------------------------
# Initialize project (framework-aware)
# -------------------------------------------------
echo ">> Initializing project"

run_as_frappe bash -c "
  set -e
  source '$VENV_DIR/bin/activate'
  cd '$PROJECT_BASE_DIR'

  if [ '$FRAMEWORK_NAME' = 'Frappe' ]; then
    if [ -n '$FRAPPE_BRANCH' ]; then
      bench init bench --frappe-branch '$FRAPPE_BRANCH' --python $PYTHON_BIN
    else
      bench init bench --python $PYTHON_BIN
    fi
  else
    echo 'ERROR: Unsupported framework: $FRAMEWORK_NAME'
    exit 1
  fi
"

# -------------------------------------------------
# Validation
# -------------------------------------------------
if ! run_as_frappe test -f "$BENCH_DIR/Procfile"; then
  echo "ERROR: Bench init failed"
  exit 1
fi

echo "== Project initialized successfully =="