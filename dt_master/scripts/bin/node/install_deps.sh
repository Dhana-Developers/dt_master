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
# Update package index
# -------------------------------------------------
apt-get update -y

# -------------------------------------------------
# Python 3.14 (required by Frappe v16)
# -------------------------------------------------
PYTHON_VERSION="3.14"

if ! command -v python${PYTHON_VERSION} >/dev/null 2>&1; then
  echo ">> Python ${PYTHON_VERSION} not found"

  if ! apt-cache show python${PYTHON_VERSION} >/dev/null 2>&1; then
    echo ">> Python ${PYTHON_VERSION} not available in current repositories"
    echo ">> Adding deadsnakes PPA"
    add-apt-repository ppa:deadsnakes/ppa -y
    apt-get update -y
  fi

  echo ">> Installing Python ${PYTHON_VERSION}"
  apt-get install -y \
    python${PYTHON_VERSION} \
    python${PYTHON_VERSION}-dev \
    python${PYTHON_VERSION}-venv
else
  echo ">> Python ${PYTHON_VERSION} already installed"
fi

# -------------------------------------------------
# Core system dependencies
# -------------------------------------------------
apt-get install -y \
  git \
  curl \
  sudo \
  redis-server \
  mariadb-server \
  mariadb-client \
  libmysqlclient-dev \
  libffi-dev \
  libssl-dev \
  libjpeg-dev \
  zlib1g-dev \
  libpq-dev \
  xvfb \
  libfontconfig1 \
  wkhtmltopdf \
  software-properties-common \
  jq \
  certbot \
  python3-certbot-nginx \
  pkg-config \
  build-essential \
  locales

# -------------------------------------------------
# Node.js 24 (required by Frappe v16)
# -------------------------------------------------
if ! node -v 2>/dev/null | grep -q "^v24"; then
  echo ">> Installing Node.js 24"
  curl -fsSL https://deb.nodesource.com/setup_24.x | bash -
  apt-get install -y nodejs
else
  echo ">> Node.js 24 already installed"
fi

# -------------------------------------------------
# Yarn
# -------------------------------------------------
if ! command -v yarn >/dev/null 2>&1; then
  echo ">> Installing Yarn"
  npm install -g yarn
else
  echo ">> Yarn already installed"
fi

# -------------------------------------------------
# Services
# -------------------------------------------------
systemctl enable redis-server mariadb
systemctl start redis-server mariadb

echo "== Dependency installation complete =="