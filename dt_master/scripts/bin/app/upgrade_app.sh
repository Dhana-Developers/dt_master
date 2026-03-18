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
require_env INSTALL_MODE REF_TYPE SOURCE_REF

APP="$APP_NAME"
APP_DIR="${BENCH_DIR}/apps/${APP}"

cd "$BENCH_DIR"

# ------------------------------------------------------------
# Guards
# ------------------------------------------------------------
if [[ "$INSTALL_MODE" != "rolling" ]]; then
    log "error=upgrade_not_supported_for_install_mode"
    exit 1
fi

if [[ "$REF_TYPE" != "branch" ]]; then
    log "error=upgrade_only_supported_for_branch_install"
    exit 1
fi

if [[ ! -d "$APP_DIR" ]]; then
    log "error=app_not_installed"
    exit 1
fi

cd "$APP_DIR"

CURRENT_BRANCH="$(run_as_frappe git branch --show-current)"

# ------------------------------------------------------------
# Rule A: upgrades must run from a branch
# ------------------------------------------------------------
if [[ -z "$CURRENT_BRANCH" ]]; then
    log "state=detached_head"
    log "action=reattach_branch"
    log "target_branch=$SOURCE_REF"

    if run_as_frappe git show-ref --verify --quiet "refs/heads/${SOURCE_REF}"; then
        run_as_frappe git checkout "${SOURCE_REF}"
    elif run_as_frappe git show-ref --verify --quiet "refs/remotes/origin/${SOURCE_REF}"; then
        run_as_frappe git checkout -B "${SOURCE_REF}" "origin/${SOURCE_REF}"
    else
        log "error=expected_branch_not_found"
        exit 1
    fi

    CURRENT_BRANCH="$SOURCE_REF"
fi

if [[ "$CURRENT_BRANCH" != "$SOURCE_REF" ]]; then
    log "error=branch_mismatch"
    log "current_branch=$CURRENT_BRANCH"
    log "expected_branch=$SOURCE_REF"
    exit 1
fi

# ------------------------------------------------------------
# Resolve git remote
# ------------------------------------------------------------
resolve_git_remote() {
    local remotes
    remotes="$(run_as_frappe git -C "$APP_DIR" remote)"

    if [[ "$(echo "$remotes" | wc -l)" -eq 1 ]]; then
        echo "$remotes"
        return 0
    fi

    return 1
}

REMOTE_NAME="$(resolve_git_remote)" || {
    echo "error=unable_to_resolve_git_remote"
    exit 1
}

# ------------------------------------------------------------
# 🔐 Ensure correct remote URL (ENFORCEMENT)
# ------------------------------------------------------------
if [[ -n "${REPOSITORY_URL:-}" ]]; then
    CURRENT_URL="$(run_as_frappe git -C "$APP_DIR" remote get-url "$REMOTE_NAME")"

    if [[ "$CURRENT_URL" != "$REPOSITORY_URL" ]]; then
        log "action=fix_remote_url"
        run_as_frappe git -C "$APP_DIR" remote set-url "$REMOTE_NAME" "$REPOSITORY_URL"
    fi
fi

# ------------------------------------------------------------
# 🔑 SSH failure handling (NEW)
# ------------------------------------------------------------
GIT_ERROR_FILE="/tmp/git_fetch_error.log"

if ! run_as_frappe git fetch "$REMOTE_NAME" "$SOURCE_REF" 2>"$GIT_ERROR_FILE"; then

    if grep -q "Permission denied (publickey)" "$GIT_ERROR_FILE"; then
        log "error=ssh_auth_failed"
        log "action=deploy_key_required"

        KEY_PATH="/home/frappe/.ssh/id_rsa"

        if [ ! -f "$KEY_PATH" ]; then
            log "action=generating_deploy_key"
            run_as_frappe mkdir -p /home/frappe/.ssh
            run_as_frappe ssh-keygen -t rsa -b 4096 -N "" -f "$KEY_PATH"
        fi

        PUB_KEY="$(run_as_frappe cat ${KEY_PATH}.pub)"

        echo "deploy_key_required=true"
        echo "deploy_key=${PUB_KEY}"

        exit 1
    fi

    log "error=git_fetch_failed"
    exit 1
fi

# ------------------------------------------------------------
# Fast-forward
# ------------------------------------------------------------
run_as_frappe git reset --hard "${REMOTE_NAME}/${SOURCE_REF}"

# ------------------------------------------------------------
# Bench lifecycle
# ------------------------------------------------------------
export NODE_OPTIONS="--max-old-space-size=4096"
export FRAPPE_NODE_OPTIONS="--max-old-space-size=4096"

bench_exec setup requirements
bench_exec --site "$SITE_NAME" migrate
bench_exec build
clear_cache_and_reload

# ------------------------------------------------------------
# Detect final state
# ------------------------------------------------------------
cd "$APP_DIR"

GIT_COMMIT="$(run_as_frappe git rev-parse --short HEAD)"
GIT_BRANCH="$(run_as_frappe git branch --show-current)"
DIRTY="false"

if run_as_frappe git status --porcelain | grep -q .; then
    DIRTY="true"
fi

INSTALLED_VERSION="$(
run_as_frappe python3 - <<'EOF'
try:
    import tomllib
    with open("pyproject.toml", "rb") as f:
        print(tomllib.load(f).get("project", {}).get("version", ""))
except Exception:
    pass
EOF
)"

# ------------------------------------------------------------
# Output
# ------------------------------------------------------------
echo "app_name=${APP}"
echo "installed=true"
echo "installed_version=${INSTALLED_VERSION}"
echo "git_commit=${GIT_COMMIT}"
echo "git_branch=${GIT_BRANCH}"
echo "git_ref=${GIT_BRANCH}"
echo "git_tag="
echo "git_head_state=branch"
echo "dirty=${DIRTY}"
echo "install_mode=${INSTALL_MODE}"
echo "ref_type=branch"
echo "source_ref=${SOURCE_REF}"