#!/usr/bin/env bash
set -uo pipefail

# -------------------------------------------------
# Verifier crash guard (script bugs ≠ site bugs)
# -------------------------------------------------
trap 'log "FATAL: verifier crashed at line $LINENO"; exit 2' ERR

# -------------------------------------------------
# Load helpers
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

BENCH_DIR="$PROJECT_BASE_DIR/bench"
SITES_DIR="$BENCH_DIR/sites"
SITE_DIR="$SITES_DIR/$SITE_NAME"
SITE_LOG_DIR="$SITE_DIR/logs"

log "Verifying site: $SITE_NAME"

# -------------------------------------------------
# HEALTH (authoritative)
# -------------------------------------------------
SYSTEM_HEALTHY=1   # runtime truth only

# -------------------------------------------------
# DIAGNOSTICS (informational)
# -------------------------------------------------
LOG_ERRORS=0
APP_ERRORS=0
IMPORT_ERRORS=0
HTTP_ERRORS=0
NGINX_ERRORS=0

# -------------------------------------------------
# Preconditions (hard failures)
# -------------------------------------------------
command -v jq >/dev/null || {
  log "FATAL: jq is required but not installed"
  exit 2
}

[ -d "$SITE_DIR" ] || { log "FATAL: Site directory not found"; exit 2; }
[ -d "$SITE_LOG_DIR" ] || { log "FATAL: Site log directory missing"; exit 2; }

SITE_CONFIG="$SITE_DIR/site_config.json"
COMMON_CONFIG="$SITES_DIR/common_site_config.json"

# -------------------------------------------------
# Site identity
# -------------------------------------------------
log "---- Site Identity ----"
jq -r '
  "Site Name        : '"$SITE_NAME"'",
  "Database         : \(.db_name // "unknown")",
  "Administrator    : \(.administrator // "unknown")",
  "Developer Mode   : \(.developer_mode // false)",
  "Maintenance Mode : \(.maintenance_mode // false)"
' "$SITE_CONFIG"

# -------------------------------------------------
# Installed apps (informational)
# -------------------------------------------------
log "---- Installed Applications ----"
bench_exec --site "$SITE_NAME" list-apps || log "WARN: list-apps failed"

# -------------------------------------------------
# Redis endpoints (runtime health)
# -------------------------------------------------
log "---- Redis Endpoints ----"
jq -r '.redis_cache?,.redis_queue?,.redis_socketio?' "$COMMON_CONFIG" \
| grep -v null \
| while read -r EP; do
  PORT="$(echo "$EP" | sed -E 's|.*:([0-9]+)$|\1|')"
  if ss -ltn | awk '{print $4}' | grep -q ":$PORT$"; then
    log "Redis OK        : $EP"
  else
    log "ERROR: Redis NOT RUNNING: $EP"
    SYSTEM_HEALTHY=0
  fi
done

# -------------------------------------------------
# Supervisor checks (PRIMARY HEALTH SIGNAL)
# -------------------------------------------------
log ">> Verifying Supervisor-managed services"
for GROUP in bench-redis bench-web bench-workers; do
  supervisorctl status "${GROUP}:*" 2>/dev/null | while read -r line; do
    case "$line" in
      *RUNNING*)
        log "OK: $line"
        ;;
      *FATAL*|*EXITED*|*STOPPED*)
        log "ERROR: $line"
        SYSTEM_HEALTHY=0
        ;;
    esac
  done
done

# -------------------------------------------------
# Log inspection helper (DIAGNOSTIC ONLY)
# -------------------------------------------------
check_log_file() {
  local file="$1"
  [ -f "$file" ] || return 0

  local content
  content="$(tail -n 400 "$file" | grep -vE 'background_jobs|/assets/|directory index of')"

  if echo "$content" | grep -qiE \
    'ModuleNotFoundError|ImportError|Traceback \(most recent call last\)|Internal Server Error'; then
    log "INFO: Diagnostic issues found in $(basename "$file")"
    echo "$content" | tail -n 20
    return 1
  fi
  return 0
}

# -------------------------------------------------
# Site logs (diagnostics only)
# -------------------------------------------------
log ">> Inspecting site logs (diagnostic)"
for LOG in frappe.log database.log scheduler.log ipython.log; do
  check_log_file "$SITE_LOG_DIR/$LOG" || LOG_ERRORS=1
done

# -------------------------------------------------
# Bench logs (diagnostics only)
# -------------------------------------------------
log ">> Inspecting bench logs (diagnostic)"
BENCH_LOG_DIR="$BENCH_DIR/logs"
for LOG in web.error.log worker.error.log; do
  FILE="$BENCH_LOG_DIR/$LOG"
  [ -f "$FILE" ] || continue

  if tail -n 300 "$FILE" | grep -F "$SITE_NAME" | grep -qiE \
    'Traceback|ModuleNotFoundError|ImportError'; then
    log "INFO: Diagnostic bench issue in $LOG"
    LOG_ERRORS=1
  fi
done

# -------------------------------------------------
# App loadability (diagnostic only)
# -------------------------------------------------
log ">> Diagnosing app loadability"
bench_exec --site "$SITE_NAME" list-apps | awk '{print $1}' | while read -r APP; do
  [ -z "$APP" ] && continue
  if [ ! -d "$BENCH_DIR/apps/$APP" ]; then
    log "INFO: App directory missing (diagnostic): $APP"
    APP_ERRORS=1
  else
    log "OK: App folder present: $APP"
  fi
done

# -------------------------------------------------
# Python import check (diagnostic only)
# -------------------------------------------------
log ">> Checking Python imports (diagnostic)"
if bench_exec --site "$SITE_NAME" console <<EOF
import frappe
frappe.init(site="$SITE_NAME")
frappe.connect()
print("Python imports OK")
exit()
EOF
then
  log "OK: Python imports successful"
else
  log "INFO: Python import issues detected (diagnostic)"
  IMPORT_ERRORS=1
fi

# -------------------------------------------------
# HTTP check (PRIMARY HEALTH SIGNAL)
# -------------------------------------------------
log ">> Verifying HTTP response"
HTTP_STATUS="$(curl -s -o /dev/null -w "%{http_code}" "http://$SITE_NAME" || true)"

if [ "$HTTP_STATUS" -ge 500 ]; then
  log "ERROR: HTTP $HTTP_STATUS returned"
  HTTP_ERRORS=1
  SYSTEM_HEALTHY=0
elif [ "$HTTP_STATUS" -ge 400 ]; then
  log "WARN: HTTP $HTTP_STATUS returned"
else
  log "OK: HTTP $HTTP_STATUS returned"
fi

# -------------------------------------------------
# Nginx upstream errors (runtime health)
# -------------------------------------------------
if [ -f /var/log/nginx/error.log ]; then
  if tail -n 300 /var/log/nginx/error.log \
     | grep -F "server: $SITE_NAME" \
     | grep -qiE 'connect\(\) failed|upstream prematurely closed'; then
    log "ERROR: Nginx upstream errors detected"
    NGINX_ERRORS=1
    SYSTEM_HEALTHY=0
  fi
fi

# -------------------------------------------------
# Final summary (ALWAYS SUCCESS)
# -------------------------------------------------
log "---- Verification Summary ----"
log "  Log issues      : $LOG_ERRORS"
log "  App issues      : $APP_ERRORS"
log "  Import issues   : $IMPORT_ERRORS"
log "  HTTP issues     : $HTTP_ERRORS"
log "  Nginx issues    : $NGINX_ERRORS"

if [ "$SYSTEM_HEALTHY" -eq 1 ]; then
  log "STATE: HEALTHY (runtime OK)"
else
  log "STATE: DEGRADED (runtime issues detected)"
fi

log "Verification completed (non-blocking)"
exit 0
