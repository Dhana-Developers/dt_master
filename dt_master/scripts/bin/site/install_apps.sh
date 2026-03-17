#!/usr/bin/env bash
set -uo pipefail

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
APPS_DIR="${BENCH_DIR}/apps"
SITE_DIR="${BENCH_DIR}/sites/${SITE_NAME}"

log "Installing apps on site: $SITE_NAME"

# -------------------------------------------------
# Input handling (NEW: structured apps support)
# -------------------------------------------------
APPS_JSON="${APPS_JSON:-}"

if [ -n "$APPS_JSON" ]; then
  log "Using structured apps input (APPS_JSON)"
  mapfile -t APP_LIST < <(echo "$APPS_JSON" | jq -c '.[]')
else
  require_env APPS
  log "Using legacy apps input (APPS): $APPS"
  IFS=',' read -ra RAW_LIST <<< "$APPS"

  APP_LIST=()
  for raw in "${RAW_LIST[@]}"; do
    app="$(echo "$raw" | xargs)"
    [ -z "$app" ] && continue

    # convert to JSON structure
    APP_LIST+=("{\"app_name\":\"$app\",\"repo_url\":null,\"ref\":null,\"ref_type\":\"branch\",\"install_strategy\":\"git_branch\"}")
  done
fi

# -------------------------------------------------
# Disable Bench automatic Supervisor reload
# -------------------------------------------------
log "Disabling automatic Supervisor reload in Bench"
bench_exec set-config -g restart_supervisor_on_update false

# -------------------------------------------------
# Node.js memory tuning
# -------------------------------------------------
export NODE_OPTIONS="--max-old-space-size=1536"
log "NODE_OPTIONS set to $NODE_OPTIONS"

# -------------------------------------------------
# Detect installed Frappe version (major)
# -------------------------------------------------
FRAPPE_VERSION_RAW="$(bench_exec version | grep -i '^frappe' || true)"

[ -z "$FRAPPE_VERSION_RAW" ] && {
  log "ERROR: Unable to determine installed Frappe version"
  exit 1
}

FRAPPE_VERSION_MAJOR="$(echo "$FRAPPE_VERSION_RAW" | awk '{print $2}' | cut -d. -f1)"

[[ ! "$FRAPPE_VERSION_MAJOR" =~ ^[0-9]+$ ]] && {
  log "ERROR: Invalid Frappe version detected: $FRAPPE_VERSION_RAW"
  exit 1
}

APP_BRANCH="version-${FRAPPE_VERSION_MAJOR}"

log "Detected Frappe version: $FRAPPE_VERSION_MAJOR"
log "Default branch: $APP_BRANCH"

# -------------------------------------------------
# Installed apps snapshot
# -------------------------------------------------
INSTALLED_APPS="$(bench_exec --site "$SITE_NAME" list-apps || true)"

# -------------------------------------------------
# Per-app processing
# -------------------------------------------------
for app_json in "${APP_LIST[@]}"; do
  app_name=$(echo "$app_json" | jq -r '.app_name')
  repo_url=$(echo "$app_json" | jq -r '.repo_url')
  ref=$(echo "$app_json" | jq -r '.ref')
  ref_type=$(echo "$app_json" | jq -r '.ref_type')
  strategy=$(echo "$app_json" | jq -r '.install_strategy')

  [ -z "$app_name" ] && continue

  log "---- Processing app: $app_name ----"

  SITE_INSTALLED=false
  FS_PRESENT=false

  echo "$INSTALLED_APPS" | grep -qx "$app_name" && SITE_INSTALLED=true
  [ -d "$APPS_DIR/$app_name" ] && FS_PRESENT=true

  # -------------------------------------------------
  # Skip healthy
  # -------------------------------------------------
  if $SITE_INSTALLED && $FS_PRESENT; then
    log "OK: Already installed: $app_name"
    continue
  fi

  log "WARN: Inconsistent state detected"
  log "  site_installed : $SITE_INSTALLED"
  log "  fs_present     : $FS_PRESENT"

  # Cleanup
  if $SITE_INSTALLED; then
    log "Uninstalling from site"
    bench_exec --site "$SITE_NAME" uninstall-app "$app_name" --yes || true
  fi

  if $FS_PRESENT; then
    log "Removing filesystem copy"
    rm -rf "$APPS_DIR/$app_name"
  fi

  # -------------------------------------------------
  # Fetch logic (FIXED)
  # -------------------------------------------------
  if [ -n "$repo_url" ] && [ "$repo_url" != "null" ]; then
    log "Custom app detected: $repo_url"

    case "$strategy" in
      git_branch|git_tag)
        if [ -n "$ref" ] && [ "$ref" != "null" ]; then
          bench_exec get-app "$repo_url" --branch "$ref"
        else
          bench_exec get-app "$repo_url"
        fi
        ;;
      git_commit)
        bench_exec get-app "$repo_url"
        cd "$APPS_DIR/$app_name"
        git checkout "$ref"
        ;;
      *)
        log "ERROR: Unknown install strategy: $strategy"
        exit 1
        ;;
    esac

  else
    log "Frappe ecosystem app: $app_name"

    if bench_exec get-app "$app_name" --branch "$APP_BRANCH"; then
      log "Fetched using $APP_BRANCH"
    else
      log "Fallback to main"
      bench_exec get-app "$app_name" --branch main
    fi
  fi

  # -------------------------------------------------
  # Install
  # -------------------------------------------------
  log "Installing app on site: $app_name"
  bench_exec --site "$SITE_NAME" install-app "$app_name"

  log "OK: Installed: $app_name"
done

# -------------------------------------------------
# Verification
# -------------------------------------------------
log "Verifying site boot"

bench_exec --site "$SITE_NAME" console <<EOF
import frappe
frappe.init(site="$SITE_NAME")
frappe.connect()
print("SITE_BOOT_OK")
exit()
EOF

# -------------------------------------------------
# Cache + reload
# -------------------------------------------------
clear_cache_and_reload

log "App installation completed successfully"