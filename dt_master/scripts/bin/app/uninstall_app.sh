#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# Bootstrap shared runtime
# ------------------------------------------------------------
source "${SCRIPT_LIB_DIR}/runtime.sh"
source "${SCRIPT_LIB_DIR}/common.sh"
source "${SCRIPT_LIB_DIR}/bench_ops.sh"

# ------------------------------------------------------------
# Required environment
# ------------------------------------------------------------
require_env BENCH_DIR APP_NAME SITE_NAME

APP="$APP_NAME"
SITE="$SITE_NAME"
APP_DIR="${BENCH_DIR}/apps/${APP}"

cd "$BENCH_DIR"

# ------------------------------------------------------------
# Guards
# ------------------------------------------------------------
if [[ ! -d "$APP_DIR" ]]; then
    log "error=app_not_present_in_bench"
    log "app=${APP}"
    exit 1
fi

# Check if app is installed on site
if ! bench_exec --site "$SITE" list-apps | grep -qx "$APP"; then
    log "error=app_not_installed_on_site"
    log "app=${APP}"
    log "site=${SITE}"
    exit 1
fi

# ------------------------------------------------------------
# Uninstall app (non-interactive)
# ------------------------------------------------------------
bench_exec --site "$SITE" uninstall-app "$APP" --yes

# ------------------------------------------------------------
# Post-uninstall hygiene
# ------------------------------------------------------------
clear_cache_and_reload

# ------------------------------------------------------------
# Output (machine contract)
# ------------------------------------------------------------
echo "app_name=${APP}"
echo "site=${SITE}"
echo "uninstalled=true"
