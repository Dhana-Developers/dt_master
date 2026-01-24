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

log "Resuming site: $SITE_NAME"

# -------------------------------------------------
# Resume site (as frappe, inside venv)
# -------------------------------------------------
bench_exec --site "$SITE_NAME" enable-scheduler
bench_exec --site "$SITE_NAME" set-maintenance-mode off

# -------------------------------------------------
# Cache clear + reload (explicit automation control)
# -------------------------------------------------
clear_cache_and_reload

log "Site resumed successfully"
