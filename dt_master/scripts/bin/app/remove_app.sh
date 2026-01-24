#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# Bootstrap shared runtime
# ------------------------------------------------------------
source "${SCRIPT_LIB_DIR}/runtime.sh"
source "${SCRIPT_LIB_DIR}/common.sh"
source "${SCRIPT_LIB_DIR}/bench_ops.sh"
source "${SCRIPT_LIB_DIR}/gc_missing_app.sh"

# ------------------------------------------------------------
# Required environment
# ------------------------------------------------------------
require_env BENCH_DIR APP_NAME

APP="$APP_NAME"
APP_DIR="${BENCH_DIR}/apps/${APP}"

cd "$BENCH_DIR"

# ------------------------------------------------------------
# Guards (self-healing)
# ------------------------------------------------------------
if [[ ! -d "$APP_DIR" ]]; then
    log "warn=app_not_present_in_bench"
    log "app=${APP}"

    GC_FOUND="$(gc_missing_app "$APP" "$BENCH_DIR")"

    if [[ "$GC_FOUND" == "true" ]]; then
        log "action=references_cleaned app=${APP}"
    fi

    # Re-validate: app must not appear anywhere
    for site in "$BENCH_DIR"/sites/*; do
        site="$(basename "$site")"
        [[ -f "$BENCH_DIR/sites/$site/apps.txt" ]] || continue

        if grep -qx "$APP" "$BENCH_DIR/sites/$site/apps.txt"; then
            log "error=reference_still_exists"
            log "site=$site app=$APP"
            exit 1
        fi
    done

    log "status=bench_consistent app=${APP}"
    exit 0
fi

# Ensure app is NOT installed on any site
INSTALLED_SITES="$(
ls -1 sites | grep -vE '^(assets|common_site_config\.json)$' | while read -r site; do
    if bench_exec --site "$site" list-apps | grep -qx "$APP"; then
        echo "$site"
    fi
done
)"

for site in sites/*; do
    site="$(basename "$site")"
    [[ -f "sites/$site/apps.txt" ]] || continue

    if grep -qx "$APP" "sites/$site/apps.txt"; then
        echo "error=app_still_referenced"
        echo "app=${APP}"
        echo "site=${site}"
        exit 1
    fi
done

if [[ -n "$INSTALLED_SITES" ]]; then
    log "error=app_still_installed_on_sites"
    log "app=${APP}"
    log "sites=${INSTALLED_SITES}"
    exit 1
fi

# ------------------------------------------------------------
# Remove app code
# ------------------------------------------------------------
rm -rf "$APP_DIR"

# ------------------------------------------------------------
# Cleanup Node artifacts (best-effort)
# ------------------------------------------------------------
rm -rf "node_modules/.cache" || true
rm -rf "apps/.vite" || true

# ------------------------------------------------------------
# Optional: rebuild assets (safe default)
# ------------------------------------------------------------
if [[ "${SKIP_BUILD:-false}" != "true" ]]; then
    export NODE_OPTIONS="--max-old-space-size=4096"
    bench_exec build
fi

# ------------------------------------------------------------
# Reload bench
# ------------------------------------------------------------
clear_cache_and_reload

# ------------------------------------------------------------
# Output (machine contract)
# ------------------------------------------------------------
echo "app_name=${APP}"
echo "removed=true"
