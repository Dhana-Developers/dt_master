#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# Bootstrap shared runtime
# ------------------------------------------------------------
source "${SCRIPT_LIB_DIR}/runtime.sh"
source "${SCRIPT_LIB_DIR}/common.sh"
source "${SCRIPT_LIB_DIR}/bench_ops.sh"
source "${SCRIPT_LIB_DIR}/python_env.sh"

# ------------------------------------------------------------
# Required environment
# ------------------------------------------------------------
require_env BENCH_DIR APP_NAME SITE_NAME
require_env INSTALL_MODE REF_TYPE TARGET_VERSION

APP="$APP_NAME"
APP_DIR="${BENCH_DIR}/apps/${APP}"

cd "$BENCH_DIR"

# ------------------------------------------------------------
# Guards
# ------------------------------------------------------------
if [[ "$INSTALL_MODE" != "rolling" ]]; then
    log "error=downgrade_not_supported_for_install_mode"
    exit 1
fi

if [[ "$REF_TYPE" != "tag" ]]; then
    log "error=downgrade_only_supported_for_tag_ref"
    exit 1
fi

if [[ ! -d "$APP_DIR" ]]; then
    log "error=app_not_installed"
    exit 1
fi

cd "$APP_DIR"

if run_as_frappe git status --porcelain | grep -q .; then
    log "error=working_tree_dirty"
    exit 1
fi

# ------------------------------------------------------------
# Resolve git remote safely
# ------------------------------------------------------------
resolve_git_remote() {
    local repo_url="${REPOSITORY_URL:-}"
    local remotes name url

    run_as_frappe git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1

    if [[ -n "$repo_url" ]]; then
        while read -r name url _; do
            [[ "$url" == "$repo_url" ]] && { echo "$name"; return 0; }
        done < <(run_as_frappe git remote -v | awk '{print $1, $2}')
    fi

    remotes="$(run_as_frappe git remote)"
    [[ "$(echo "$remotes" | wc -l)" -eq 1 ]] && echo "$remotes" && return 0

    return 1
}

REMOTE_NAME="$(resolve_git_remote)" || {
    log "error=unable_to_resolve_git_remote"
    exit 1
}

# ------------------------------------------------------------
# Fetch & checkout target tag (downgrade)
# ------------------------------------------------------------
log "Fetching tags from remote=${REMOTE_NAME}"
run_as_frappe git fetch --tags "$REMOTE_NAME"

if ! run_as_frappe git rev-parse "refs/tags/${TARGET_VERSION}" >/dev/null 2>&1; then
    log "error=target_version_not_found"
    log "target_version=${TARGET_VERSION}"
    exit 1
fi

log "Checking out tag=${TARGET_VERSION}"
run_as_frappe git checkout -f "tags/${TARGET_VERSION}"

# ------------------------------------------------------------
# Bench lifecycle (venv-safe, memory-safe, build-safe)
# ------------------------------------------------------------
export NODE_OPTIONS="--max-old-space-size=4096"
export FRAPPE_NODE_OPTIONS="--max-old-space-size=4096"

bench_exec setup requirements
bench_exec --site "$SITE_NAME" migrate
bench_exec build
clear_cache_and_reload

# ------------------------------------------------------------
# Detect final state (authoritative)
# ------------------------------------------------------------
cd "$APP_DIR"

GIT_COMMIT="$(run_as_frappe git rev-parse --short HEAD)"
GIT_TAG="$TARGET_VERSION"
DIRTY="false"

if run_as_frappe git status --porcelain | grep -q .; then
    DIRTY="true"
fi

INSTALLED_VERSION="$(
run_as_frappe python3 - <<'EOF'
try:
    import tomllib
except ModuleNotFoundError:
    import tomli as tomllib

try:
    with open("pyproject.toml", "rb") as f:
        print(tomllib.load(f).get("project", {}).get("version", ""))
except Exception:
    pass
EOF
)"

# ------------------------------------------------------------
# Output (machine contract)
# ------------------------------------------------------------
echo "app_name=${APP}"
echo "installed=true"
echo "installed_version=${INSTALLED_VERSION}"
echo "git_commit=${GIT_COMMIT}"
echo "git_branch="
echo "git_ref=${GIT_TAG}"
echo "git_tag=${GIT_TAG}"
echo "git_head_state=detached"
echo "dirty=${DIRTY}"
echo "install_mode=${INSTALL_MODE}"
echo "ref_type=tag"
echo "target_version=${TARGET_VERSION}"
