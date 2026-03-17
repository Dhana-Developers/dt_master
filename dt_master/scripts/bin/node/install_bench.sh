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
# Resolve framework context (base64 → JSON)
# -------------------------------------------------
FRAMEWORK_CONTEXT="{}"

if [ -n "${FRAMEWORK_CONTEXT_B64:-}" ]; then
    if command -v base64 >/dev/null 2>&1; then
        FRAMEWORK_CONTEXT=$(echo "$FRAMEWORK_CONTEXT_B64" | base64 -d || echo "{}")
    else
        echo "WARNING: base64 not available, cannot decode FRAMEWORK_CONTEXT"
    fi
fi

# -------------------------------------------------
# Resolve runtime (JSON → fallback → defaults)
# -------------------------------------------------

# Try JSON first (source of truth)
PYTHON_VERSION_JSON=""
BENCH_PACKAGE_JSON=""

if command -v jq >/dev/null 2>&1; then
    if echo "$FRAMEWORK_CONTEXT" | jq empty >/dev/null 2>&1; then
        PYTHON_VERSION_JSON=$(echo "$FRAMEWORK_CONTEXT" | jq -r '.python_version // empty')
        BENCH_PACKAGE_JSON=$(echo "$FRAMEWORK_CONTEXT" | jq -r '.bench_package // empty')
    else
        echo "WARNING: Invalid FRAMEWORK_CONTEXT JSON"
    fi
fi

# Fallback to env if JSON missing
PYTHON_VERSION="${PYTHON_VERSION_JSON:-${PYTHON_VERSION:-}}"
BENCH_PACKAGE="${BENCH_PACKAGE_JSON:-${BENCH_PACKAGE:-}}"

# Final safety defaults
: "${PYTHON_VERSION:?PYTHON_VERSION is required}"
: "${BENCH_PACKAGE:=frappe-bench}"

# -------------------------------------------------
# Logging
# -------------------------------------------------
exec > >(tee -a "$PROJECT_LOGS_DIR/install_bench.log") 2>&1

echo "== Installing Bench (dynamic) =="

echo ">> Python version: $PYTHON_VERSION"
echo ">> Bench package: $BENCH_PACKAGE"

VENV_DIR="$PROJECT_BASE_DIR/.venv"
PYTHON_BIN="python${PYTHON_VERSION}"

# -------------------------------------------------
# Validate Python
# -------------------------------------------------
if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
    echo "ERROR: $PYTHON_BIN not found. Required Python version is missing."
    exit 1
fi

echo ">> Using Python: $PYTHON_BIN"

# -------------------------------------------------
# Create virtual environment
# -------------------------------------------------
if ! run_as_frappe test -d "$VENV_DIR"; then
    echo ">> Creating virtual environment at $VENV_DIR"
    run_as_frappe "$PYTHON_BIN" -m venv "$VENV_DIR"
else
    echo ">> Virtual environment already exists"
fi

# -------------------------------------------------
# Install bench dynamically
# -------------------------------------------------
run_as_frappe bash -c "
    set -e

    source '$VENV_DIR/bin/activate'

    echo '>> Upgrading pip toolchain'
    pip install --upgrade pip setuptools wheel

    echo '>> Installing bench package: $BENCH_PACKAGE'
    pip install $BENCH_PACKAGE

    echo '>> Verifying installation'
    python - <<'EOF'
import os
from importlib.metadata import version

pkg = os.environ.get('BENCH_PACKAGE', 'frappe-bench')
print(f'{pkg} version:', version(pkg))
EOF
"

echo "== Bench installed successfully =="