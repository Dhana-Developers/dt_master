#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------
# Load runtime (privilege + user guarantees)
# -------------------------------------------------
: "${SCRIPT_LIB_DIR:?}"

RUNTIME_SH="${SCRIPT_LIB_DIR}/runtime.sh"
if [ ! -f "$RUNTIME_SH" ]; then
  echo "ERROR: runtime.sh not found at $RUNTIME_SH"
  exit 1
fi

# shellcheck source=/dev/null
source "$RUNTIME_SH"

require_root

# -------------------------------------------------
# Required environment variables
# -------------------------------------------------
: "${PROJECT_BASE_DIR:?}"
: "${PROJECT_LOGS_DIR:?}"

# -------------------------------------------------
# Logging (root-owned by design)
# -------------------------------------------------
exec > >(tee -a "$PROJECT_LOGS_DIR/install_bench.log") 2>&1

echo "== Installing Frappe Bench (project venv) =="

VENV_DIR="$PROJECT_BASE_DIR/.venv"

# -------------------------------------------------
# Create venv as frappe
# -------------------------------------------------
if ! run_as_frappe test -d "$VENV_DIR"; then
    echo "Creating virtual environment at $VENV_DIR"
    run_as_frappe python3 -m venv "$VENV_DIR"
fi

# -------------------------------------------------
# Install bench inside venv (as frappe)
# -------------------------------------------------
run_as_frappe bash -c "
    set -e
    source '$VENV_DIR/bin/activate'
    pip install --upgrade pip setuptools wheel
    pip install frappe-bench

    # Context-safe verification (DO NOT call bench CLI yet)
    python - <<'EOF'
from importlib.metadata import version
print('frappe-bench version:', version('frappe-bench'))
EOF
"

echo "== Bench installed successfully in venv =="
