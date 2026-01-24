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
# Load venv helpers (run_in_venv)
# -------------------------------------------------
: "${SCRIPT_LIB_DIR:?}"
source "$SCRIPT_LIB_DIR/python_env.sh"

# -------------------------------------------------
# Required environment variables
# -------------------------------------------------
: "${PROJECT_BASE_DIR:?}"
: "${SITE_NAME:?}"

BENCH_DIR="${PROJECT_BASE_DIR}/bench"

# -------------------------------------------------
# Bench execution helpers (ALWAYS inside venv)
# -------------------------------------------------

bench_exec() {
  if [ "$#" -eq 0 ]; then
    echo "ERROR: bench_exec requires bench arguments"
    exit 1
  fi

  if [ "$1" = "bench" ]; then
    echo "ERROR: Do not pass 'bench' to bench_exec"
    exit 1
  fi

  if [ ! -d "$PROJECT_BASE_DIR/bench" ]; then
    echo "ERROR: Bench directory not found at $PROJECT_BASE_DIR/bench"
    exit 1
  fi

  (
    cd "$PROJECT_BASE_DIR/bench" || exit 1
    run_in_venv bench "$@"
  )
}





# -------------------------------------------------
# Cache clear + reload (context-safe)
# -------------------------------------------------

clear_cache_and_reload() {
  bench_exec --site "$SITE_NAME" clear-cache
  bench_exec --site "$SITE_NAME" clear-website-cache

  # Supervisor reload is ROOT responsibility
  if [ -S /var/run/supervisor.sock ] && supervisorctl pid >/dev/null 2>&1; then
    supervisorctl reread
    supervisorctl update
  else
    log \"WARN: Supervisor not available for reload\"
  fi
}

# -------------------------------------------------
# Site existence check
# -------------------------------------------------

site_exists() {
  local site="$SITE_NAME"

  if [ -z "$site" ]; then
    echo "ERROR: SITE_NAME not set"
    exit 1
  fi

  # Bench must be run from bench directory
  if [ ! -d "$PROJECT_BASE_DIR/bench/sites/$site" ]; then
    return 1
  fi

  # Basic sanity check (site config must exist)
  if [ ! -f "$PROJECT_BASE_DIR/bench/sites/$site/site_config.json" ]; then
    return 1
  fi

  return 0
}

