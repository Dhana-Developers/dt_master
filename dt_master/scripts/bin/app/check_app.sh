#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# Bootstrap shared runtime
# ------------------------------------------------------------

source "${SCRIPT_LIB_DIR}/runtime.sh"
source "${SCRIPT_LIB_DIR}/common.sh"
source "${SCRIPT_LIB_DIR}/bench_ops.sh"
source "${SCRIPT_LIB_DIR}/python_env.sh"

require_env BENCH_DIR SITE_NAME APP_NAME

cd "$BENCH_DIR"

APP="$APP_NAME"
APP_DIR="${BENCH_DIR}/apps/${APP}"

INSTALLED="false"
INSTALLED_VERSION=""

# Git state
GIT_COMMIT=""
GIT_REF=""
GIT_TAG=""
HEAD_STATE="unknown"
DIRTY="false"
GIT_BRANCH=""

# ------------------------------------------------------------
# Detect installation + git state
# ------------------------------------------------------------

if [[ -d "$APP_DIR" ]]; then
    INSTALLED="true"

    if run_as_frappe git -C "$APP_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        GIT_COMMIT="$(run_as_frappe git -C "$APP_DIR" rev-parse --short HEAD)"

        if run_as_frappe git -C "$APP_DIR" status --porcelain | grep -q .; then
            DIRTY="true"
        else
            DIRTY="false"
        fi

        if run_as_frappe git -C "$APP_DIR" symbolic-ref -q HEAD >/dev/null 2>&1; then
            HEAD_STATE="branch"
            GIT_BRANCH="$(run_as_frappe git -C "$APP_DIR" branch --show-current)"
            GIT_REF="$GIT_BRANCH"

        else
            HEAD_STATE="detached"
            GIT_TAG="$(run_as_frappe git -C "$APP_DIR" describe --tags --exact-match 2>/dev/null || true)"
            GIT_REF="${GIT_TAG:-detached}"
        fi
    else
        HEAD_STATE="no-git"
    fi
fi

# ------------------------------------------------------------
# Installed version detection (global, value-driven)
# ------------------------------------------------------------

INSTALLED_VERSION=""

# 1. Exact git tag (strongest)
if [[ -z "$INSTALLED_VERSION" && -n "$GIT_TAG" ]]; then
    INSTALLED_VERSION="$GIT_TAG"
fi

# 2. Runtime Python package version (frappe + others)
if [[ -z "$INSTALLED_VERSION" ]]; then
    INSTALLED_VERSION="$(
        run_as_frappe python3 - <<EOF
try:
    mod = __import__("$APP")
    print(getattr(mod, "__version__", ""))
except Exception:
    pass
EOF
    )"
fi

# 3. Static pyproject.toml [project].version
if [[ -z "$INSTALLED_VERSION" && -f "$APP_DIR/pyproject.toml" ]]; then
    INSTALLED_VERSION="$(
        run_as_frappe python3 - <<'EOF'
try:
    import tomllib  # Python 3.11+
except ModuleNotFoundError:
    import tomli as tomllib  # Python <= 3.10

try:
    with open("pyproject.toml", "rb") as f:
        data = tomllib.load(f)
    print(data.get("project", {}).get("version", ""))
except Exception:
    pass

EOF
    )"
fi

# 4. Static __init__.py __version__ (legacy apps)
if [[ -z "$INSTALLED_VERSION" && -f "$APP_DIR/$APP/__init__.py" ]]; then
    INSTALLED_VERSION="$(
        run_as_frappe python3 - <<EOF
import re
try:
    with open("$APP_DIR/$APP/__init__.py") as f:
        for line in f:
            if "__version__" in line:
                m = re.search(r"['\"]([^'\"]+)['\"]", line)
                if m:
                    print(m.group(1))
except Exception:
    pass
EOF
    )"
fi

# 5. Branch fallback (last resort)
if [[ -z "$INSTALLED_VERSION" && "$HEAD_STATE" == "branch" ]]; then
    INSTALLED_VERSION="$GIT_REF"
fi

# ------------------------------------------------------------
# Output (machine contract: key=value)
# ------------------------------------------------------------

echo "app_name=${APP}"
echo "installed=${INSTALLED}"
echo "installed_version=${INSTALLED_VERSION}"
echo "git_commit=${GIT_COMMIT}"
echo "git_branch=${GIT_BRANCH}"
echo "git_ref=${GIT_REF}"
echo "git_tag=${GIT_TAG}"
echo "head_state=${HEAD_STATE}"
echo "dirty=${DIRTY}"
