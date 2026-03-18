#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------
# Constants
# -------------------------------------------------
FRAPPE_USER="frappe"
FRAPPE_SHELL="/bin/bash"
SUDOERS_FILE="/etc/sudoers.d/frappe"

# -------------------------------------------------
# Root enforcement
# -------------------------------------------------
require_root() {

  if [ "$(id -u)" -eq 0 ]; then
    return 0
  fi

  if sudo -n true 2>/dev/null; then
    return 0
  fi

  echo "ERROR: This script requires root privileges or passwordless sudo"
  exit 1
}

# -------------------------------------------------
# Ensure service user exists
# -------------------------------------------------
ensure_frappe_user() {
  if ! id "$FRAPPE_USER" &>/dev/null; then
    echo "INFO: Creating user '$FRAPPE_USER'"
    sudo useradd -m -s "$FRAPPE_SHELL" "$FRAPPE_USER"
  fi
}

# -------------------------------------------------
# Ensure passwordless sudo (idempotent)
# -------------------------------------------------
ensure_frappe_sudo() {
  if [ ! -f "$SUDOERS_FILE" ]; then
    echo "INFO: Granting passwordless sudo to '$FRAPPE_USER'"
    echo "$FRAPPE_USER ALL=(ALL) NOPASSWD:ALL" | sudo tee "$SUDOERS_FILE" >/dev/null
    sudo chmod 440 "$SUDOERS_FILE"
  fi
}

run_as_frappe() {
  require_root
  ensure_frappe_user
  ensure_frappe_sudo

  sudo -u "$FRAPPE_USER" \
    --preserve-env=PROJECT_BASE_DIR,PROJECT_LOGS_DIR,NODE_VERSION,SKIP_NVM \
    env HOME="/home/$FRAPPE_USER" \
    bash -lc '
      set -e

      # -------------------------------------------------
      # Conditionally load NVM
      # -------------------------------------------------
      if [ "${SKIP_NVM:-0}" != "1" ]; then

        export NVM_DIR="$HOME/.nvm"

        if [ -s "$NVM_DIR/nvm.sh" ]; then
          source "$NVM_DIR/nvm.sh"

          if [ -n "${NODE_VERSION:-}" ]; then
            nvm use "$NODE_VERSION" >/dev/null || {
              echo "ERROR: Failed to activate Node $NODE_VERSION via nvm" >&2
              exit 1
            }
          fi
        fi

        # Validate Node exists (NO stdout pollution)
        if ! command -v node >/dev/null 2>&1; then
          echo "ERROR: Node not available in frappe environment" >&2
          exit 1
        fi

      fi

      # -------------------------------------------------
      # Execute command (stdout = pure result)
      # -------------------------------------------------
      "$@"
    ' bash "$@"
}