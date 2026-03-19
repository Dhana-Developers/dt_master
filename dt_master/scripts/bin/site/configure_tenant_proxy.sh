#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------
# Load helpers (CURRENT CONTEXT)
# -------------------------------------------------
: "${SCRIPT_LIB_DIR:?}"
source "$SCRIPT_LIB_DIR/common.sh"

# -------------------------------------------------
# Must run as root
# -------------------------------------------------
require_root

# -------------------------------------------------
# Required environment variables
# -------------------------------------------------
require_env \
  SITE_NAME \
  FRAPPE_UPSTREAM_PORT \
  PROJECT_BASE_DIR \
  TENANT_PROTOCOL

TENANT_PROTOCOL="$(echo "$TENANT_PROTOCOL" | tr '[:upper:]' '[:lower:]')"

case "$TENANT_PROTOCOL" in
  http|https) ;;
  *)
    log "ERROR: TENANT_PROTOCOL must be 'http' or 'https'"
    exit 1
    ;;
esac

# -------------------------------------------------
# Paths & constants
# -------------------------------------------------
NGINX_CONF_DIR="/etc/nginx/conf.d"
NGINX_CONF_FILE="${NGINX_CONF_DIR}/tenant_${SITE_NAME}.conf"

FRAPPE_UPSTREAM="127.0.0.1:${FRAPPE_UPSTREAM_PORT}"
ASSETS_PATH="${PROJECT_BASE_DIR}/bench/sites/assets"

CERTBOT_BIN="$(command -v certbot || true)"
LE_LIVE_DIR="/etc/letsencrypt/live/${SITE_NAME}"

log "Configuring Nginx for tenant"
log "Protocol    : ${TENANT_PROTOCOL}"
log "FQDN        : ${SITE_NAME}"
log "Upstream    : ${FRAPPE_UPSTREAM}"
log "Assets path : ${ASSETS_PATH}"

# -------------------------------------------------
# Preconditions
# -------------------------------------------------
if [ ! -d "$ASSETS_PATH" ]; then
  log "ERROR: Assets directory not found: $ASSETS_PATH"
  exit 1
fi

if [ "$TENANT_PROTOCOL" = "https" ] && [ -z "$CERTBOT_BIN" ]; then
  log "ERROR: certbot not installed but HTTPS requested"
  exit 1
fi

# -------------------------------------------------
# Ensure asset directory permissions for Nginx
# -------------------------------------------------
log "Ensuring asset directory permissions"

chmod o+x /home || true
chmod o+x "$(dirname "$PROJECT_BASE_DIR")" || true
chmod o+x "$PROJECT_BASE_DIR" || true
chmod o+x "$PROJECT_BASE_DIR/bench" || true
chmod o+x "$PROJECT_BASE_DIR/bench/sites" || true
chmod -R o+rX "$ASSETS_PATH" || true

# -------------------------------------------------
# Ensure WebSocket upgrade map exists (global)
# -------------------------------------------------
NGINX_MAP_FILE="/etc/nginx/conf.d/websocket_map.conf"

if [ ! -f "$NGINX_MAP_FILE" ]; then
  log "Creating Nginx WebSocket map config"

  cat >"$NGINX_MAP_FILE" <<EOF
# WebSocket connection upgrade mapping
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
}
EOF
else
  log "WebSocket map config already exists"
fi

# -------------------------------------------------
# Write HTTP server block (always)
# -------------------------------------------------
log "Writing Nginx HTTP config: $NGINX_CONF_FILE"

cat >"$NGINX_CONF_FILE" <<EOF
# -------------------------------------------------
# Auto-generated tenant proxy (HTTP)
# Tenant: ${SITE_NAME}
# -------------------------------------------------

server {
    listen 80;
    server_name ${SITE_NAME};

    client_max_body_size 50m;

    location /assets/ {
        alias ${ASSETS_PATH}/;
        expires 1y;
        add_header Cache-Control "public";
        access_log off;
    }

    location /socket.io {
        proxy_pass http://127.0.0.1:9000;
        proxy_http_version 1.1;

        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;

        proxy_set_header Host \$host;
        proxy_set_header Origin \$scheme://\$host;

        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
    }

    location / {
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Port 80;
        proxy_set_header X-Real-IP \$remote_addr;

        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_read_timeout 120;
        proxy_connect_timeout 120;

        proxy_pass http://${FRAPPE_UPSTREAM};
    }
}
EOF

# -------------------------------------------------
# Validate & reload Nginx (HTTP)
# -------------------------------------------------
log "Validating Nginx (HTTP)"
nginx -t

log "Reloading Nginx (HTTP)"
systemctl reload nginx

# -------------------------------------------------
# Optional: Add local /etc/hosts entry (dev only)
# -------------------------------------------------
if [ "${LOCAL_HOSTS_ENTRY:-false}" = "true" ]; then
  log "Ensuring local /etc/hosts entry for ${SITE_NAME}"

  HOSTS_LINE="127.0.0.1 ${SITE_NAME}"

  if grep -qE "^[[:space:]]*127\.0\.0\.1[[:space:]]+${SITE_NAME}(\$|[[:space:]])" /etc/hosts; then
    log "/etc/hosts already contains entry for ${SITE_NAME}"
  else
    log "Adding /etc/hosts entry: ${HOSTS_LINE}"
    echo "${HOSTS_LINE}" >> /etc/hosts
  fi
else
  log "LOCAL_HOSTS_ENTRY disabled — skipping /etc/hosts modification"
fi


# -------------------------------------------------
# HTTPS setup (ONLY if requested)
# -------------------------------------------------
if [ "$TENANT_PROTOCOL" = "https" ]; then
  log "HTTPS enabled for tenant"

  if [ ! -d "$LE_LIVE_DIR" ]; then
    log "Issuing Let's Encrypt certificate for ${SITE_NAME}"

    certbot certonly \
      --nginx \
      --non-interactive \
      --agree-tos \
      --register-unsafely-without-email \
      -d "${SITE_NAME}"
  else
    log "SSL already exists for ${SITE_NAME}, skipping certificate issuance"
  fi

  if ! grep -q "listen 443 ssl" "$NGINX_CONF_FILE"; then
    log "Adding HTTPS server block"

    cat >>"$NGINX_CONF_FILE" <<EOF

# -------------------------------------------------
# Auto-generated tenant proxy (HTTPS)
# Tenant: ${SITE_NAME}
# -------------------------------------------------

server {
    listen 443 ssl http2;
    server_name ${SITE_NAME};

    ssl_certificate     /etc/letsencrypt/live/${SITE_NAME}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${SITE_NAME}/privkey.pem;

    client_max_body_size 50m;

    location /assets/ {
        alias ${ASSETS_PATH}/;
        expires 1y;
        add_header Cache-Control "public";
        access_log off;
    }

    location /socket.io {
        proxy_pass http://127.0.0.1:9000;
        proxy_http_version 1.1;

        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;

        proxy_set_header Host \$host;
        proxy_set_header Origin \$scheme://\$host;

        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
    }

    location / {
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Port 443;
        proxy_set_header X-Real-IP \$remote_addr;

        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_read_timeout 120;
        proxy_connect_timeout 120;

        proxy_pass http://${FRAPPE_UPSTREAM};
    }
}
EOF
  fi

  log "Validating Nginx (HTTPS)"
  nginx -t

  log "Reloading Nginx (HTTPS)"
  systemctl reload nginx
else
  log "Protocol is HTTP only — skipping HTTPS and certbot"
fi

log "Tenant Nginx configuration completed successfully"
