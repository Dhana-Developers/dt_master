#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------
# Load helpers (CURRENT CONTEXT)
# -------------------------------------------------
: "${SCRIPT_LIB_DIR:?}"

source "$SCRIPT_LIB_DIR/common.sh"
source "$SCRIPT_LIB_DIR/python_env.sh"
source "$SCRIPT_LIB_DIR/bench_ops.sh"

# -------------------------------------------------
# Required environment variables
# -------------------------------------------------
require_env \
  SITE_NAME \
  PROJECT_BASE_DIR \
  PROJECT_LOGS_DIR

BENCH_DIR="${PROJECT_BASE_DIR}/bench"
SITE_DIR="${BENCH_DIR}/sites/${SITE_NAME}"
BENCH_LOG_DIR="${BENCH_DIR}/logs"

log "Destroying site: $SITE_NAME"

# -------------------------------------------------
# Ensure frappe owns required paths (CRITICAL FIX)
# -------------------------------------------------
log "Ensuring frappe ownership for bench paths"

for path in "$BENCH_DIR" "$BENCH_LOG_DIR" "$SITE_DIR"; do
  if [ -e "$path" ]; then
    chown -R frappe:frappe "$path"
  fi
done

# -------------------------------------------------
# Drop site via Bench (authoritative)
# -------------------------------------------------
if [ -d "$SITE_DIR" ]; then
  log "Dropping site via bench"
  bench_exec drop-site "$SITE_NAME" --force
else
  log "Site directory not found, skipping bench drop"
fi

# -------------------------------------------------
# Defensive filesystem cleanup
# -------------------------------------------------
if [ -d "$SITE_DIR" ]; then
  log "Removing residual site directory"
  rm -rf "$SITE_DIR"
fi

# -------------------------------------------------
# Reload services (safe)
# -------------------------------------------------
clear_cache_and_reload

log "Site destroyed permanently"