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

  # Case 1: actual root user
  if [ "$(id -u)" -eq 0 ]; then
    return 0
  fi

  # Case 2: sudo available without password
  if sudo -n true 2>/dev/null; then
    return 0
  fi

  echo "ERROR: This script requires root privileges or a user with passwordless sudo"
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
# Ensure passwordless sudo for frappe (idempotent)
# -------------------------------------------------
ensure_frappe_sudo() {
  if [ ! -f "$SUDOERS_FILE" ]; then
    echo "INFO: Granting passwordless sudo to '$FRAPPE_USER'"
    echo "$FRAPPE_USER ALL=(ALL) NOPASSWD:ALL" | sudo tee "$SUDOERS_FILE"
    sudo chmod 440 "$SUDOERS_FILE"
  fi
}

# -------------------------------------------------
# Run command as frappe (safe, idempotent)
# -------------------------------------------------
run_as_frappe() {
  require_root
  ensure_frappe_user
  ensure_frappe_sudo

  sudo -u "$FRAPPE_USER" \
    --preserve-env=PROJECT_BASE_DIR,PROJECT_LOGS_DIR \
    "$@"
}
