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
require_env INSTALL_MODE REF_TYPE REPOSITORY_URL
: "${FRAPPE_HOME:?FRAPPE_HOME not set}"

APP="$APP_NAME"
APPS_DIR="${BENCH_DIR}/apps"
SSH_KEY="${FRAPPE_HOME}/.ssh/id_ed25519"

cd "$BENCH_DIR"

# ------------------------------------------------------------
# Guards (contract enforcement)
# ------------------------------------------------------------
case "$INSTALL_MODE" in
  rolling|fixed) ;;
  *)
    log "error=invalid_install_mode"
    log "expected=rolling|fixed"
    log "got=${INSTALL_MODE}"
    exit 1
    ;;
esac

case "$INSTALL_MODE:$REF_TYPE" in
  rolling:branch|fixed:tag) ;;
  *)
    log "error=install_mode_ref_mismatch"
    log "install_mode=$INSTALL_MODE"
    log "ref_type=$REF_TYPE"
    exit 1
    ;;
esac

# ------------------------------------------------------------
# 🔐 SSH deploy-key bootstrap (idempotent & ownership-safe)
# ------------------------------------------------------------
ensure_ssh_key() {
    mkdir -p "${FRAPPE_HOME}/.ssh"
    chown -R frappe:frappe "${FRAPPE_HOME}/.ssh"
    chmod 700 "${FRAPPE_HOME}/.ssh"

    if [[ ! -f "$SSH_KEY" ]]; then
        log "action=generate_ssh_deploy_key"
        run_as_frappe ssh-keygen \
            -t ed25519 \
            -f "$SSH_KEY" \
            -N "" \
            -C "dtsaas-deploy"
    fi

    run_as_frappe touch "${FRAPPE_HOME}/.ssh/known_hosts"
    run_as_frappe chmod 600 "${FRAPPE_HOME}/.ssh/known_hosts"

    # IMPORTANT: no shell redirection outside run_as_frappe
    run_as_frappe ssh-keyscan github.com 2>/dev/null | \
    run_as_frappe tee -a "${FRAPPE_HOME}/.ssh/known_hosts" >/dev/null
}

# ------------------------------------------------------------
# Ensure GitHub SSH access (bench relies on git)
# ------------------------------------------------------------
if [[ "$REPOSITORY_URL" == https://github.com/* ]]; then
    ensure_ssh_key
    SSH_REPO="$(echo "$REPOSITORY_URL" | sed -E 's#https://github.com/#git@github.com:#')"

    if ! run_as_frappe git ls-remote "$SSH_REPO" >/dev/null 2>&1; then
        log "error=ssh_deploy_key_not_authorized"
        log "action=add_public_key_to_github_deploy_keys"
        PUB_KEY="$(run_as_frappe cat "${SSH_KEY}.pub")"
        log "public_key=${PUB_KEY}"
        exit 1
    fi

    REPOSITORY_URL="$SSH_REPO"
    log "repo_switched_to_ssh=${REPOSITORY_URL}"
fi

# ------------------------------------------------------------
# Fetch app using BENCH ONLY (third-party SAFE)
# ------------------------------------------------------------
if [[ ! -d "$APPS_DIR/$APP" ]]; then
    log "Fetching app via bench: $APP"

    if [[ "$REF_TYPE" == "branch" ]]; then
        require_env SOURCE_REF
        bench_exec get-app \
            "$APP" \
            "$REPOSITORY_URL" \
            --branch "$SOURCE_REF"
    else
        require_env TARGET_VERSION
        bench_exec get-app \
            "$APP" \
            "$REPOSITORY_URL" \
            --tag "$TARGET_VERSION"
    fi
fi

# ------------------------------------------------------------
# Install app on site (bench-authoritative)
# ------------------------------------------------------------
log "Installing app on site via bench: $APP"

if ! bench_exec --site "$SITE_NAME" install-app "$APP"; then
    log "error=bench_install_failed"
    log "app=$APP"
    bench_exec --site "$SITE_NAME" uninstall-app "$APP" --yes || true
    exit 1
fi

# ------------------------------------------------------------
# Bench lifecycle
# ------------------------------------------------------------
export NODE_OPTIONS="--max-old-space-size=4096"
export FRAPPE_NODE_OPTIONS="$NODE_OPTIONS"

bench_exec build
clear_cache_and_reload

# ------------------------------------------------------------
# Detect final state (safe git probing)
# ------------------------------------------------------------
APP_DIR="${APPS_DIR}/${APP}"

GIT_COMMIT="$(
  run_as_frappe git -C "$APP_DIR" rev-parse --short HEAD 2>/dev/null || true
)"
GIT_BRANCH="$(
  run_as_frappe git -C "$APP_DIR" branch --show-current 2>/dev/null || true
)"
DIRTY="false"
if run_as_frappe git -C "$APP_DIR" status --porcelain 2>/dev/null | grep -q .; then
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
echo "git_branch=${GIT_BRANCH}"
echo "git_ref=${GIT_BRANCH:-${TARGET_VERSION:-}}"
echo "git_tag=${TARGET_VERSION:-}"
echo "git_head_state=$( [[ -z "$GIT_BRANCH" ]] && echo detached || echo branch )"
echo "dirty=${DIRTY}"
echo "install_mode=${INSTALL_MODE}"
echo "ref_type=${REF_TYPE}"
echo "source_ref=${SOURCE_REF:-}"
echo "target_version=${TARGET_VERSION:-}"
