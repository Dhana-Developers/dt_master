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
# Virtualenv helpers (robust + context-aware)
# -------------------------------------------------

require_venv() {
  : "${PROJECT_BASE_DIR:?}"

  VENV_DIR="$PROJECT_BASE_DIR/.venv"
  VENV_ACTIVATE="$VENV_DIR/bin/activate"

  if [ ! -f "$VENV_ACTIVATE" ]; then
    echo "ERROR: Python virtualenv not found at $VENV_DIR"
    exit 1
  fi
}

# -------------------------------------------------
# Run a command inside the venv AS FRAPPE
# - Reuses venv if already active
# - Activates temporarily if not
# - Deactivates safely after execution
# -------------------------------------------------
run_in_venv() {
  require_venv

  # -------------------------------------------------
  # Guard rails: forbid nested shells & injection
  # -------------------------------------------------

  if [ "$#" -eq 0 ]; then
    echo "ERROR: run_in_venv requires a command"
    exit 1
  fi

  case "$1" in
    bash|sh|sudo)
      echo "ERROR: run_in_venv does not allow '$1'"
      echo "Use direct command invocation only"
      exit 1
      ;;
  esac

  # Reject common shell execution patterns
  for arg in "$@"; do
    case "$arg" in
      *";"*|*"&&"*|*"||"*|*"|"*|*\`*|*\$\(*)
        echo "ERROR: run_in_venv does not allow shell operators or command substitution"
        exit 1
        ;;
    esac
  done



  # -------------------------------------------------
  # Execute command inside venv as frappe
  # -------------------------------------------------

  run_as_frappe bash -c '
    set -e

    VENV_ACTIVATE="$PROJECT_BASE_DIR/.venv/bin/activate"

    if [ -z "$VIRTUAL_ENV" ]; then
      source "$VENV_ACTIVATE"
      _DT_VENV_TEMP_ACTIVATED=1
    fi

    "$@"

    if [ "${_DT_VENV_TEMP_ACTIVATED:-}" = "1" ]; then
      deactivate
    fi
  ' -- "$@"
}


