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
  APPS \
  PROJECT_BASE_DIR \
  PROJECT_LOGS_DIR

BENCH_DIR="${PROJECT_BASE_DIR}/bench"
APPS_DIR="${BENCH_DIR}/apps"
SITE_DIR="${BENCH_DIR}/sites/${SITE_NAME}"

log "Installing apps on site: $SITE_NAME"
log "Requested apps: $APPS"

# -------------------------------------------------
# Disable Bench automatic Supervisor reload (CRITICAL)
# -------------------------------------------------
log "Disabling automatic Supervisor reload in Bench (automation-safe)"
bench_exec set-config -g restart_supervisor_on_update false

# -------------------------------------------------
# Node.js memory tuning for low-memory servers
# -------------------------------------------------
export NODE_OPTIONS="--max-old-space-size=1536"
log "NODE_OPTIONS set to $NODE_OPTIONS"

# -------------------------------------------------
# Detect installed Frappe version (major)
# -------------------------------------------------
FRAPPE_VERSION_RAW="$(bench_exec version | grep -i '^frappe' || true)"

if [ -z "$FRAPPE_VERSION_RAW" ]; then
  log "ERROR: Unable to determine installed Frappe version"
  exit 1
fi

FRAPPE_VERSION_MAJOR="$(echo "$FRAPPE_VERSION_RAW" | awk '{print $2}' | cut -d. -f1)"

if [[ ! "$FRAPPE_VERSION_MAJOR" =~ ^[0-9]+$ ]]; then
  log "ERROR: Invalid Frappe version detected: $FRAPPE_VERSION_RAW"
  exit 1
fi

APP_BRANCH="version-${FRAPPE_VERSION_MAJOR}"

log "Detected Frappe major version: $FRAPPE_VERSION_MAJOR"
log "Using app branch: $APP_BRANCH"

# -------------------------------------------------
# Installed apps on site (snapshot)
# -------------------------------------------------
INSTALLED_APPS="$(bench_exec --site "$SITE_NAME" list-apps || true)"

IFS=',' read -ra APP_LIST <<< "$APPS"

# -------------------------------------------------
# Per-app processing (NO bench console here)
# -------------------------------------------------
for raw_app in "${APP_LIST[@]}"; do
  app="$(echo "$raw_app" | xargs)"
  [ -z "$app" ] && continue

  log "---- Processing app: $app ----"

  SITE_INSTALLED=false
  FS_PRESENT=false

  echo "$INSTALLED_APPS" | grep -qx "$app" && SITE_INSTALLED=true
  [ -d "$APPS_DIR/$app" ] && FS_PRESENT=true

  # -------------------------------------------------
  # Case: fully healthy → skip
  # -------------------------------------------------
  if $SITE_INSTALLED && $FS_PRESENT; then
    log "OK: App already installed and filesystem present: $app"
    continue
  fi

  # -------------------------------------------------
  # Case: broken / partial install → repair
  # -------------------------------------------------
  log "WARN: Inconsistent app state detected for $app"
  log "  site_installed : $SITE_INSTALLED"
  log "  fs_present     : $FS_PRESENT"

  # Remove broken site registration
  if $SITE_INSTALLED; then
    log "Removing app from site registry: $app"
    bench_exec --site "$SITE_NAME" uninstall-app "$app" --yes || true
  fi

  # Remove broken filesystem copy
  if $FS_PRESENT; then
    log "Removing broken app directory: $APPS_DIR/$app"
    rm -rf "$APPS_DIR/$app"
  fi

  # Re-fetch app cleanly
  log "Fetching app fresh: $app (preferred branch: $APP_BRANCH)"

  if bench_exec get-app "$app" --branch "$APP_BRANCH"; then
    log "Fetched $app using branch $APP_BRANCH"
  else
    log "WARN: Branch $APP_BRANCH not found for $app, falling back to main"
    bench_exec get-app "$app" --branch main
  fi


  # Install app on site
  log "Installing app on site: $app"
  bench_exec --site "$SITE_NAME" install-app "$app"

  log "OK: App installed/repaired: $app"
done

# -------------------------------------------------
# GLOBAL verification (SINGLE bench console call)
# -------------------------------------------------
log "Verifying site boots after app installation"

bench_exec --site "$SITE_NAME" console <<EOF
import frappe
frappe.init(site="$SITE_NAME")
frappe.connect()
print("SITE_BOOT_OK")
exit()
EOF

# -------------------------------------------------
# Cache clear + reload (explicit, controlled)
# -------------------------------------------------
clear_cache_and_reload

log "App installation completed successfully"
