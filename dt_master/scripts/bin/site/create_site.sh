#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------
# Load helpers (FILENAMES UNCHANGED)
# -------------------------------------------------
: "${SCRIPT_LIB_DIR:?}"

source "$SCRIPT_LIB_DIR/runtime.sh"
source "$SCRIPT_LIB_DIR/common.sh"
source "$SCRIPT_LIB_DIR/python_env.sh"
source "$SCRIPT_LIB_DIR/bench_ops.sh"

# -------------------------------------------------
# Must run as root
# -------------------------------------------------
require_root

# -------------------------------------------------
# Required environment variables
# -------------------------------------------------
require_env \
  SITE_NAME \
  DB_NAME \
  ADMIN_PASSWORD \
  MYSQL_ROOT_USER \
  MYSQL_ROOT_PASSWORD \
  PROJECT_BASE_DIR \
  PROJECT_LOGS_DIR \
  FRAPPE_UPSTREAM_PORT

BENCH_DIR="${PROJECT_BASE_DIR}/bench"
SUPERVISOR_LINK="/etc/supervisor/conf.d/bench.conf"
TARGET_SUPERVISOR_CONF="$BENCH_DIR/config/supervisor.conf"

log "Starting site setup: $SITE_NAME"
log "Using Frappe upstream port: $FRAPPE_UPSTREAM_PORT"

# -------------------------------------------------
# Ensure MariaDB user exists (NEW SAFETY STEP)
# -------------------------------------------------
ensure_db_user() {

  log "Ensuring MariaDB admin user '${MYSQL_ROOT_USER}'@'localhost' exists"

  mysql <<SQL
DROP USER IF EXISTS '${MYSQL_ROOT_USER}'@'localhost';

CREATE USER '${MYSQL_ROOT_USER}'@'localhost'
IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}';

ALTER USER '${MYSQL_ROOT_USER}'@'localhost'
IDENTIFIED VIA mysql_native_password;

SET PASSWORD FOR '${MYSQL_ROOT_USER}'@'localhost'
= PASSWORD('${MYSQL_ROOT_PASSWORD}');

GRANT ALL PRIVILEGES ON *.* TO '${MYSQL_ROOT_USER}'@'localhost'
WITH GRANT OPTION;

FLUSH PRIVILEGES;
SQL

  log "MariaDB admin user '${MYSQL_ROOT_USER}' ready"

}

ensure_db_user

# -------------------------------------------------
# Idempotency check (DO NOT EXIT SCRIPT)
# -------------------------------------------------
repair_partial_site() {

  log "Repairing partial site installation"

  rm -rf "$BENCH_DIR/sites/$SITE_NAME"

  mysql <<SQL
DROP DATABASE IF EXISTS \`$DB_NAME\`;
DROP USER IF EXISTS '$DB_NAME'@'localhost';
FLUSH PRIVILEGES;
SQL

  log "Partial site removed — clean installation will proceed"
}

check_partial_site() {

  SITE_PATH="$BENCH_DIR/sites/$SITE_NAME"
  SITE_CONFIG="$SITE_PATH/site_config.json"

  if [ ! -d "$SITE_PATH" ]; then
    return 1
  fi

  if [ ! -f "$SITE_CONFIG" ]; then
    log "Site config missing — partial installation detected"
    return 0
  fi

  DB_USER=$(jq -r '.db_user // empty' "$SITE_CONFIG")
  DB_PASS=$(jq -r '.db_password // empty' "$SITE_CONFIG")
  DB_NAME_LOCAL=$(jq -r '.db_name // empty' "$SITE_CONFIG")

  if [ -z "$DB_USER" ] || [ -z "$DB_NAME_LOCAL" ]; then
    log "DB credentials missing in site_config.json"
    return 0
  fi

  if ! mysql -u"$DB_USER" -p"$DB_PASS" -e "USE \`$DB_NAME_LOCAL\`;" >/dev/null 2>&1; then
    log "Database authentication failed — partial site detected"
    return 0
  fi

  return 1
}

CREATE_SITE=1

if site_exists; then

  if check_partial_site; then
    log "Partial site installation detected"
    repair_partial_site
    CREATE_SITE=1
  else
    log "Site already exists and is healthy"
    CREATE_SITE=0
  fi

fi

# -------------------------------------------------
# Create site (only if missing)
# -------------------------------------------------
if [ "$CREATE_SITE" -eq 1 ]; then
  log "Creating new site: $SITE_NAME"

  bench_exec new-site "$SITE_NAME" \
    --db-name "$DB_NAME" \
    --admin-password "$ADMIN_PASSWORD" \
    --mariadb-root-username "$MYSQL_ROOT_USER" \
    --mariadb-root-password "$MYSQL_ROOT_PASSWORD"
else
  log "Using existing site: $SITE_NAME"
fi

# -------------------------------------------------
# Post-creation / post-existence site setup
# -------------------------------------------------
log "Running post-creation site setup"
(
  cd "$BENCH_DIR" || exit 1
  run_in_venv bench --site "$SITE_NAME" migrate
  run_in_venv bench --site "$SITE_NAME" enable-scheduler
)

# -------------------------------------------------
# 🌐 Set public site URL (CRITICAL)
# -------------------------------------------------
log "Setting public site_url for Frappe"
(
  cd "$BENCH_DIR" || exit 1
  run_in_venv bench set-config -g site_url "https://$SITE_NAME"
)

#-------------------------------------------------
#🔐 Lock Gunicorn port at Bench level (CRITICAL)
#-------------------------------------------------
log "Configuring Bench webserver port: $FRAPPE_UPSTREAM_PORT"
log "Temporarily setting webserver_port for supervisor generation"
(
  cd "$BENCH_DIR" || exit 1
  run_in_venv bench set-config -g webserver_port "$FRAPPE_UPSTREAM_PORT"
)

# -------------------------------------------------
# Ensure Supervisor is wired to THIS bench
# -------------------------------------------------
log "Ensuring Supervisor is bound to current bench path"

if [ -L "$SUPERVISOR_LINK" ]; then
  CURRENT_TARGET="$(readlink -f "$SUPERVISOR_LINK")"
  if [ "$CURRENT_TARGET" != "$TARGET_SUPERVISOR_CONF" ]; then
    log "Updating Supervisor bench.conf symlink"
    rm -f "$SUPERVISOR_LINK"
  fi
elif [ -e "$SUPERVISOR_LINK" ]; then
  log "WARNING: bench.conf exists but is not a symlink — replacing"
  rm -f "$SUPERVISOR_LINK"
fi

if [ ! -e "$SUPERVISOR_LINK" ]; then
  log "Linking Supervisor to bench config"
  ln -s "$TARGET_SUPERVISOR_CONF" "$SUPERVISOR_LINK"
fi

# -------------------------------------------------
# Regenerate Supervisor config (non-interactive)
# -------------------------------------------------
log "Reconfiguring Supervisor for site-level services"

log "Stopping Supervisor-managed Bench services"
supervisorctl stop bench-web:* bench-workers:* || true

(
  cd "$BENCH_DIR" || exit 1
  run_as_frappe bash -c "
    set -e
    source '$PROJECT_BASE_DIR/.venv/bin/activate'
    export CI=1
    bench setup supervisor --yes
  "
)

log "Removing webserver_port to prevent public URL leakage"
(
  cd "$BENCH_DIR" || exit 1
  run_in_venv bench set-config -g webserver_port ''
)

log "Reloading Supervisor configuration"
supervisorctl reread
supervisorctl update

log "Starting Supervisor-managed Bench services"
supervisorctl start bench-redis:* bench-web:* bench-workers:* || true

log "Verifying public URL does not include internal port"
if run_in_venv bench --site "$SITE_NAME" execute frappe.utils.get_url \
  | grep -q ":$FRAPPE_UPSTREAM_PORT"; then
  log "ERROR: Public URL still leaking internal port"
  exit 1
fi

log "Verifying Gunicorn is bound to expected port"
if ! ss -ltnp | grep -q "127.0.0.1:$FRAPPE_UPSTREAM_PORT"; then
  log "ERROR: Gunicorn not bound to expected port $FRAPPE_UPSTREAM_PORT"
  exit 1
fi

# -------------------------------------------------
# Cache clear + reload
# -------------------------------------------------
clear_cache_and_reload

log "Site setup completed successfully"