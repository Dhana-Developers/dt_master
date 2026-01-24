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
# Create project directories as frappe
# -------------------------------------------------
run_as_frappe mkdir -p "$PROJECT_BASE_DIR" "$PROJECT_LOGS_DIR"

# Safety net (idempotent)
chown -R frappe:frappe "$PROJECT_BASE_DIR" "$PROJECT_LOGS_DIR"

# -------------------------------------------------
# Logging
# -------------------------------------------------
exec > >(tee -a "$PROJECT_LOGS_DIR/install_deps.log") 2>&1

echo "== Installing system dependencies (Frappe) =="

export DEBIAN_FRONTEND=noninteractive

# -------------------------------------------------
# Root-only system packages
# -------------------------------------------------
apt-get update -y

apt-get install -y \
  git \
  curl \
  sudo \
  python3-dev \
  python3-pip \
  python3-setuptools \
  python3-venv \
  redis-server \
  mariadb-server \
  mariadb-client \
  libmysqlclient-dev \
  xvfb \
  libfontconfig \
  wkhtmltopdf \
  software-properties-common\
  jq\
  certbot\
  python3-certbot-nginx\
  python3-tomli

# -------------------------------------------------
# Node.js 18 (required by Frappe)
# -------------------------------------------------
if ! node -v 2>/dev/null | grep -q "^v18"; then
  curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
  apt-get install -y nodejs
fi

# -------------------------------------------------
# Yarn
# -------------------------------------------------
if ! command -v yarn >/dev/null 2>&1; then
  npm install -g yarn
fi

# -------------------------------------------------
# Services
# -------------------------------------------------
systemctl enable redis-server mariadb
systemctl start redis-server mariadb

echo "== Dependency installation complete =="
