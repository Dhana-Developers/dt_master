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
: "${SYSTEM_DEPENDENCIES:?}"

# -------------------------------------------------
# Create project directories as frappe
# -------------------------------------------------
SKIP_NVM=1 run_as_frappe mkdir -p "$PROJECT_BASE_DIR" "$PROJECT_LOGS_DIR"
chown -R frappe:frappe "$PROJECT_BASE_DIR" "$PROJECT_LOGS_DIR"

# -------------------------------------------------
# Logging
# -------------------------------------------------
exec > >(tee -a "$PROJECT_LOGS_DIR/install_deps.log") 2>&1

echo "== Installing system dependencies (dynamic) =="

export DEBIAN_FRONTEND=noninteractive

# -------------------------------------------------
# Ensure jq exists (bootstrap dependency)
# -------------------------------------------------
if ! command -v jq >/dev/null 2>&1; then
  echo ">> Installing jq (bootstrap)"
  apt-get update -y
  apt-get install -y jq
fi

# -------------------------------------------------
# Update package index
# -------------------------------------------------
apt-get update -y

# -------------------------------------------------
# Install dependencies dynamically
# -------------------------------------------------
echo "$SYSTEM_DEPENDENCIES" | jq -c '.[]' | while read -r dep; do

  NAME=$(echo "$dep" | jq -r '.name')
  METHOD=$(echo "$dep" | jq -r '.install_method')
  GROUP=$(echo "$dep" | jq -r '.group')
  VERSION=$(echo "$dep" | jq -r '.version // empty')
  REPO=$(echo "$dep" | jq -r '.repository // empty')

  echo "-------------------------------------------------"
  echo ">> Processing: $NAME"
  echo "   Method: $METHOD | Group: $GROUP | Version: $VERSION"

  case "$METHOD" in

    apt)
      if [ -n "$REPO" ]; then
        echo ">> Adding repository: $REPO"
        add-apt-repository -y "$REPO" || true
        apt-get update -y
      fi

      echo ">> Installing via apt: $NAME"
      apt-get install -y "$NAME"
      ;;

    pip)
      echo ">> Installing via pip: $NAME"
      pip install "$NAME"
      ;;

    npm)
      echo ">> Installing via npm: $NAME"
      npm install -g "$NAME"
      ;;

    nvm)
      echo ">> Installing Node via nvm: $VERSION"

      SKIP_NVM=1 run_as_frappe bash -c "
        export NVM_DIR=\"\$HOME/.nvm\"
        [ -s \"\$NVM_DIR/nvm.sh\" ] && source \"\$NVM_DIR/nvm.sh\"

        if ! command -v nvm >/dev/null 2>&1; then
          echo 'ERROR: nvm not installed'
          exit 1
        fi

        nvm install $VERSION
        nvm use $VERSION
      "
      ;;

    script)
      echo ">> Running script for: $NAME"
      if [ -z "$REPO" ]; then
        echo "ERROR: script dependency missing repository"
        exit 1
      fi

      SKIP_NVM=1 run_as_frappe bash -c "
        curl -fsSL \"$REPO\" | bash
      "
      ;;

    *)
      echo "ERROR: Unknown install method: $METHOD"
      exit 1
      ;;

  esac

done

# -------------------------------------------------
# Enable and start services (still system-level)
# -------------------------------------------------
echo ">> Ensuring core services are running"

systemctl enable redis-server mariadb || true
systemctl start redis-server mariadb || true

echo "== Dependency installation complete =="