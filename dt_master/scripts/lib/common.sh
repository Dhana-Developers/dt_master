#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------
# Load shared runtime (privilege + helpers)
# -------------------------------------------------
: "${SCRIPT_LIB_DIR:?}"

RUNTIME_SH="${SCRIPT_LIB_DIR}/runtime.sh"
[ -f "$RUNTIME_SH" ] || { echo "runtime.sh not found"; exit 1; }

# shellcheck source=/dev/null
source "$RUNTIME_SH"

# -------------------------------------------------
# Logging initialization (site-scoped, idempotent)
# -------------------------------------------------
if [ -z "${_DT_SITE_LOGGING_INITIALIZED:-}" ]; then
  : "${PROJECT_LOGS_DIR:?}"
  : "${SITE_NAME:?}"

  export _DT_SITE_LOGGING_INITIALIZED=1

  SITE_LOG_DIR="${PROJECT_LOGS_DIR}/tenant_sites"
  mkdir -p "$SITE_LOG_DIR"

  LOG_FILE="${SITE_LOG_DIR}/${SITE_NAME}.log"

  # Global stdout + stderr redirection (streaming, root-owned)
  exec > >(tee -a "$LOG_FILE") 2>&1
fi

# -------------------------------------------------
# Utilities
# -------------------------------------------------

require_env() {
  for var in "$@"; do
    if [ -z "${!var:-}" ]; then
      log "ERROR: Missing required env var: $var"
      exit 1
    fi
  done
}

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}
