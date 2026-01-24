#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# Interactive helpers
# ------------------------------------------------------------
prompt_if_empty() {
    local var_name="$1"
    local prompt="$2"
    local silent="${3:-false}"
    local value

    if [[ -z "${!var_name:-}" ]]; then
        if [[ "$silent" == "true" ]]; then
            read -rsp "$prompt: " value
            echo
        else
            read -rp "$prompt: " value
        fi
        printf -v "$var_name" '%s' "$value"
        export "$var_name"
    fi
}

# ------------------------------------------------------------
# Configuration (env or interactive)
# ------------------------------------------------------------
prompt_if_empty TARGET_USERNAME "Enter username"

TARGET_HOME="${TARGET_HOME:-/home/$TARGET_USERNAME}"
TARGET_SHELL="${TARGET_SHELL:-/bin/bash}"

ADD_SUDO="${ADD_SUDO:-}"
if [[ -z "$ADD_SUDO" ]]; then
    read -rp "Add user to sudo group? [y/N]: " yn
    [[ "$yn" =~ ^[Yy]$ ]] && ADD_SUDO=true || ADD_SUDO=false
fi

SET_PASSWORD="${SET_PASSWORD:-}"
if [[ -z "$SET_PASSWORD" ]]; then
    read -rp "Set password for user? [y/N]: " yn
    [[ "$yn" =~ ^[Yy]$ ]] && SET_PASSWORD=true || SET_PASSWORD=false
fi

if [[ "$SET_PASSWORD" == "true" ]]; then
    if [[ -z "${TARGET_PASSWORD:-}" ]]; then
        while true; do
            read -rsp "Enter password: " TARGET_PASSWORD
            echo
            read -rsp "Confirm password: " CONFIRM_PASSWORD
            echo
            [[ "$TARGET_PASSWORD" == "$CONFIRM_PASSWORD" ]] && break
            echo "Passwords do not match. Try again."
        done
    fi
fi

# ------------------------------------------------------------
# Guards
# ------------------------------------------------------------
if id "$TARGET_USERNAME" &>/dev/null; then
    echo "status=user_exists user=$TARGET_USERNAME"
    exit 0
fi

# ------------------------------------------------------------
# Create user
# ------------------------------------------------------------
useradd \
    --create-home \
    --home-dir "$TARGET_HOME" \
    --shell "$TARGET_SHELL" \
    "$TARGET_USERNAME"

# ------------------------------------------------------------
# Set password
# ------------------------------------------------------------
if [[ "$SET_PASSWORD" == "true" ]]; then
    echo "$TARGET_USERNAME:$TARGET_PASSWORD" | chpasswd
    echo "password_set=true"
fi

# ------------------------------------------------------------
# Add to sudo group
# ------------------------------------------------------------
if [[ "$ADD_SUDO" == "true" ]]; then
    usermod -aG sudo "$TARGET_USERNAME"
    echo "sudo_enabled=true"
fi

# ------------------------------------------------------------
# Harden permissions
# ------------------------------------------------------------
chmod 700 "$TARGET_HOME"

# ------------------------------------------------------------
# Output (machine-readable)
# ------------------------------------------------------------
echo "user_created=true"
echo "username=$TARGET_USERNAME"
echo "home=$TARGET_HOME"
echo "shell=$TARGET_SHELL"
echo "sudo=$ADD_SUDO"
