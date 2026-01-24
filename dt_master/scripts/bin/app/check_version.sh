#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# Bootstrap shared runtime
# ------------------------------------------------------------
source "${SCRIPT_LIB_DIR}/runtime.sh"
source "${SCRIPT_LIB_DIR}/common.sh"
source "${SCRIPT_LIB_DIR}/bench_ops.sh"
source "${SCRIPT_LIB_DIR}/python_env.sh"

require_env BENCH_DIR APP_NAME

cd "$BENCH_DIR"

APP="$APP_NAME"
APP_DIR="${BENCH_DIR}/apps/${APP}"

INSTALLED="false"
INSTALLED_VERSION=""

# Git state
GIT_COMMIT=""
GIT_REF=""
GIT_TAG=""
GIT_BRANCH=""
HEAD_STATE="unknown"
DIRTY="false"

# Update state
UPDATE_AVAILABLE="unknown"

# Marketplace metadata (exported by executor)
INSTALL_MODE="${INSTALL_MODE:-}"
REPOSITORY_URL="${REPOSITORY_URL:-}"
REF_TYPE="${REF_TYPE:-}"
SOURCE_REF="${SOURCE_REF:-}"

# ------------------------------------------------------------
# Detect installation + git state
# ------------------------------------------------------------
if [[ -d "$APP_DIR" ]]; then
    INSTALLED="true"

    if run_as_frappe git -C "$APP_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        GIT_COMMIT="$(run_as_frappe git -C "$APP_DIR" rev-parse --short HEAD)"

        if run_as_frappe git -C "$APP_DIR" status --porcelain | grep -q .; then
            DIRTY="true"
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
# Installed version detection (authoritative)
# ------------------------------------------------------------
INSTALLED_VERSION=""

if [[ -z "$INSTALLED_VERSION" && -n "$GIT_TAG" ]]; then
    INSTALLED_VERSION="$GIT_TAG"
fi

if [[ -z "$INSTALLED_VERSION" ]]; then
    INSTALLED_VERSION="$(
        run_as_frappe python3 - <<EOF
try:
    mod = __import__("${APP}")
    print(getattr(mod, "__version__", ""))
except Exception:
    pass
EOF
    )"
fi

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

if [[ -z "$INSTALLED_VERSION" && "$HEAD_STATE" == "branch" ]]; then
    INSTALLED_VERSION="$GIT_REF"
fi

# ------------------------------------------------------------
# Marketplace-aware update detection
# ------------------------------------------------------------
UPDATE_AVAILABLE="unknown"

if [[ "$INSTALL_MODE" == "rolling" && "$REF_TYPE" == "branch" ]]; then
    if [[ -n "$REPOSITORY_URL" && -n "$SOURCE_REF" && -n "$GIT_COMMIT" ]]; then
        REMOTE_COMMIT="$(
            run_as_frappe git ls-remote "$REPOSITORY_URL" "refs/heads/${SOURCE_REF}" 2>/dev/null \
            | awk '{print substr($1,1,7)}'
        )"

        if [[ -n "$REMOTE_COMMIT" ]]; then
            [[ "$REMOTE_COMMIT" != "$GIT_COMMIT" ]] && UPDATE_AVAILABLE="true" || UPDATE_AVAILABLE="false"
        fi
    fi
fi

# ------------------------------------------------------------
# Branch-based major upgrade detection
# ------------------------------------------------------------
UPGRADE_AVAILABLE="false"
UPGRADE_TARGET=""
UPGRADE_LATEST=""

if [[ "$INSTALL_MODE" == "rolling" && "$REF_TYPE" == "branch" && "$SOURCE_REF" =~ ^version-([0-9]+)$ ]]; then
    CURRENT_MAJOR="${BASH_REMATCH[1]}"

    REMOTE_MAJORS="$(
        run_as_frappe git ls-remote "$REPOSITORY_URL" "refs/heads/version-*" \
        | awk -F/ '{print $NF}' \
        | sed 's/version-//' \
        | grep -E '^[0-9]+$' \
        | sort -n
    )"

    for v in $REMOTE_MAJORS; do
        if (( v > CURRENT_MAJOR )); then
            UPGRADE_AVAILABLE="true"
            UPGRADE_TARGET="version-${v}"
            break
        fi
    done

    UPGRADE_LATEST="version-$(echo "$REMOTE_MAJORS" | tail -n1)"
fi

# ------------------------------------------------------------
# Semantic version discovery (FULL versions from tags)
# ------------------------------------------------------------
NEXT_MAJOR_VERSION=""
LATEST_MAJOR_VERSION=""
NEXT_MINOR_VERSION=""
LATEST_MINOR_VERSION=""
NEXT_PATCH_VERSION=""
LATEST_PATCH_VERSION=""

SEMVER_TAGS="$(
    run_as_frappe git ls-remote --tags "$REPOSITORY_URL" 2>/dev/null \
    | awk -F/ '{print $NF}' \
    | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' \
    | sed 's/^v//' \
    | sort -V
)"

if [[ "$INSTALLED_VERSION" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    CUR_MAJOR="${BASH_REMATCH[1]}"
    CUR_MINOR="${BASH_REMATCH[2]}"
    CUR_PATCH="${BASH_REMATCH[3]}"

    # ---------- LATEST MAJOR (highest X.Y.Z overall)
    LATEST_MAJOR_VERSION="$(echo "$SEMVER_TAGS" | tail -n1)"

    # ---------- NEXT MAJOR (first tag with X > current major)
    NEXT_MAJOR_VERSION="$(
        echo "$SEMVER_TAGS" \
        | awk -F. -v m="$CUR_MAJOR" '$1 > m' \
        | head -n1
    )"

    # ---------- LATEST MINOR (same major, highest Y.Z)
    LATEST_MINOR_VERSION="$(
        echo "$SEMVER_TAGS" \
        | awk -F. -v m="$CUR_MAJOR" '$1 == m' \
        | tail -n1
    )"

    # ---------- NEXT MINOR (same major, Y > current minor)
    NEXT_MINOR_VERSION="$(
        echo "$SEMVER_TAGS" \
        | awk -F. -v m="$CUR_MAJOR" -v n="$CUR_MINOR" '$1 == m && $2 > n' \
        | head -n1
    )"

    # ---------- LATEST PATCH (same major+minor)
    LATEST_PATCH_VERSION="$(
        echo "$SEMVER_TAGS" \
        | awk -F. -v m="$CUR_MAJOR" -v n="$CUR_MINOR" '$1 == m && $2 == n' \
        | tail -n1
    )"

    # ---------- NEXT PATCH (same major+minor, Z > current patch)
    NEXT_PATCH_VERSION="$(
        echo "$SEMVER_TAGS" \
        | awk -F. -v m="$CUR_MAJOR" -v n="$CUR_MINOR" -v p="$CUR_PATCH" \
            '$1 == m && $2 == n && $3 > p' \
        | head -n1
    )"
fi

# ------------------------------------------------------------
# Fallbacks → resolve to installed version if empty
# ------------------------------------------------------------
NEXT_MAJOR_VERSION="${NEXT_MAJOR_VERSION:-$INSTALLED_VERSION}"
LATEST_MAJOR_VERSION="${LATEST_MAJOR_VERSION:-$INSTALLED_VERSION}"
NEXT_MINOR_VERSION="${NEXT_MINOR_VERSION:-$INSTALLED_VERSION}"
LATEST_MINOR_VERSION="${LATEST_MINOR_VERSION:-$INSTALLED_VERSION}"
NEXT_PATCH_VERSION="${NEXT_PATCH_VERSION:-$INSTALLED_VERSION}"
LATEST_PATCH_VERSION="${LATEST_PATCH_VERSION:-$INSTALLED_VERSION}"

# ------------------------------------------------------------
# Output (machine contract)
# ------------------------------------------------------------
echo "app_name=${APP}"
echo "installed=${INSTALLED}"
echo "installed_version=${INSTALLED_VERSION}"
echo "git_commit=${GIT_COMMIT}"
echo "git_branch=${GIT_BRANCH}"
echo "git_ref=${GIT_REF}"
echo "git_tag=${GIT_TAG}"
echo "git_head_state=${HEAD_STATE}"
echo "dirty=${DIRTY}"
echo "install_mode=${INSTALL_MODE}"
echo "ref_type=${REF_TYPE}"
echo "source_ref=${SOURCE_REF}"
echo "update_available=${UPDATE_AVAILABLE}"
echo "upgrade_available=${UPGRADE_AVAILABLE}"
echo "upgrade_target=${UPGRADE_TARGET}"
echo "upgrade_latest=${UPGRADE_LATEST}"

echo "next_major_version=${NEXT_MAJOR_VERSION}"
echo "latest_major_version=${LATEST_MAJOR_VERSION}"
echo "next_minor_version=${NEXT_MINOR_VERSION}"
echo "latest_minor_version=${LATEST_MINOR_VERSION}"
echo "next_patch_version=${NEXT_PATCH_VERSION}"
echo "latest_patch_version=${LATEST_PATCH_VERSION}"
