#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------
prompt_if_empty() {
    local var="$1"
    local prompt="$2"
    local value

    if [[ -z "${!var:-}" ]]; then
        read -rp "$prompt: " value
        if [[ -z "$value" ]]; then
            echo "error=missing_${var}"
            exit 1
        fi
        printf -v "$var" '%s' "$value"
        export "$var"
    fi
}

require_clean_worktree() {
    if ! git diff --quiet || ! git diff --cached --quiet; then
        echo "error=working_tree_dirty"
        git status --short
        exit 1
    fi
}

require_branch() {
    local expected="$1"
    local current
    current="$(git branch --show-current)"

    if [[ "$current" != "$expected" ]]; then
        echo "error=branch_mismatch"
        echo "current_branch=$current"
        echo "expected_branch=$expected"
        exit 1
    fi
}

# ------------------------------------------------------------
# Repository detection
# ------------------------------------------------------------
detect_repo_name() {
    # Try remote URL first
    local remote url
    remote="${REMOTE_NAME:-origin}"

    if url="$(git remote get-url "$remote" 2>/dev/null)"; then
        basename "${url%.git}"
        return 0
    fi

    # Fallback: directory name
    basename "$(pwd)"
}

# ------------------------------------------------------------
# Inputs (env or interactive)
# ------------------------------------------------------------
REPO_NAME="${REPO_NAME:-$(detect_repo_name || true)}"
prompt_if_empty REPO_NAME "Enter repository name"

prompt_if_empty DEVELOP_BRANCH "Enter develop branch name (e.g. develop)"
prompt_if_empty VERSION_BRANCH "Enter version branch (e.g. version-1)"
prompt_if_empty RELEASE_VERSION "Enter release tag (e.g. v1.1.0)"
prompt_if_empty RELEASE_MESSAGE "Enter release message"

REMOTE_NAME="${REMOTE_NAME:-origin}"

# ------------------------------------------------------------
# Preconditions
# ------------------------------------------------------------
require_clean_worktree
require_branch "$DEVELOP_BRANCH"

# ------------------------------------------------------------
# Create annotated tag
# ------------------------------------------------------------
if git rev-parse "$RELEASE_VERSION" >/dev/null 2>&1; then
    echo "error=tag_already_exists tag=$RELEASE_VERSION"
    exit 1
fi

echo "== [$REPO_NAME] Tagging release $RELEASE_VERSION =="
git tag -a "$RELEASE_VERSION" -m "$RELEASE_MESSAGE"

# ------------------------------------------------------------
# Update version branch (fast-forward only)
# ------------------------------------------------------------
echo "== [$REPO_NAME] Updating $VERSION_BRANCH =="

if git show-ref --verify --quiet "refs/heads/$VERSION_BRANCH"; then
    git checkout "$VERSION_BRANCH"
else
    echo "info=creating_version_branch branch=$VERSION_BRANCH"
    git checkout -b "$VERSION_BRANCH" "$RELEASE_VERSION"
fi

git merge --ff-only "$RELEASE_VERSION"

# ------------------------------------------------------------
# Push
# ------------------------------------------------------------
echo "== [$REPO_NAME] Pushing to $REMOTE_NAME =="
git push "$REMOTE_NAME" "$RELEASE_VERSION"
git push "$REMOTE_NAME" "$VERSION_BRANCH"

# ------------------------------------------------------------
# Restore develop branch (authoring context)
# ------------------------------------------------------------
echo "== [$REPO_NAME] Restoring develop branch =="
git checkout "$DEVELOP_BRANCH"

# ------------------------------------------------------------
# Done
# ------------------------------------------------------------
echo "status=release_complete"
echo "repo_name=$REPO_NAME"
echo "release_tag=$RELEASE_VERSION"
echo "version_branch=$VERSION_BRANCH"
echo "remote=$REMOTE_NAME"
