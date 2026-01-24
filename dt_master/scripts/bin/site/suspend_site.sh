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

log "Suspending site: $SITE_NAME"

# -------------------------------------------------
# Suspend site (as frappe, inside venv)
# -------------------------------------------------
bench_exec --site "$SITE_NAME" disable-scheduler
bench_exec --site "$SITE_NAME" set-maintenance-mode on

# -------------------------------------------------
# Cache clear + reload (explicit automation control)
# -------------------------------------------------
clear_cache_and_reload

log "Site suspended successfully"
