#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# Runtime bootstrap
# ------------------------------------------------------------
source "${SCRIPT_LIB_DIR}/runtime.sh"
source "${SCRIPT_LIB_DIR}/common.sh"

require_root

log "Configuring Rspamd"

# ------------------------------------------------------------
# Required environment
# ------------------------------------------------------------
: "${MAIL_DOMAIN:?MAIL_DOMAIN not set}"
: "${MAIL_HOSTNAME:?MAIL_HOSTNAME not set}"

# ------------------------------------------------------------
# Paths
# ------------------------------------------------------------
RSPAMD_DIR="/etc/rspamd"
LOCAL_D="${RSPAMD_DIR}/local.d"

mkdir -p "$LOCAL_D"

# ------------------------------------------------------------
# Worker configuration
# ------------------------------------------------------------
log "Configuring Rspamd worker"

cat > "${LOCAL_D}/worker-proxy.inc" <<EOF
bind_socket = "127.0.0.1:11332";
milter = yes;
timeout = 120s;
upstream "local" {
  default = yes;
  self_scan = yes;
}
EOF

# ------------------------------------------------------------
# Redis configuration
# ------------------------------------------------------------
log "Configuring Redis backend"

cat > "${LOCAL_D}/redis.conf" <<EOF
servers = "127.0.0.1";
EOF

# ------------------------------------------------------------
# DKIM signing placeholder
# ------------------------------------------------------------
log "Preparing DKIM signing configuration"

cat > "${LOCAL_D}/dkim_signing.conf" <<EOF
path = "/var/lib/rspamd/dkim/\$domain.\$selector.key";
selector = "mail";
allow_envfrom_empty = true;
allow_hdrfrom_mismatch = true;
sign_authenticated = true;
sign_local = true;
use_domain = "header";
EOF

# ------------------------------------------------------------
# Spam filtering tuning
# ------------------------------------------------------------
log "Applying spam filtering policy"

cat > "${LOCAL_D}/actions.conf" <<EOF
reject = 15;
add_header = 6;
greylist = 4;
EOF

# ------------------------------------------------------------
# Ensure directories
# ------------------------------------------------------------
log "Preparing Rspamd directories"

mkdir -p /var/lib/rspamd
mkdir -p /var/lib/rspamd/dkim

chown -R _rspamd:_rspamd /var/lib/rspamd

# ------------------------------------------------------------
# Enable service
# ------------------------------------------------------------
log "Enabling Rspamd service"

systemctl enable rspamd
systemctl restart rspamd

# ------------------------------------------------------------
# Verify service
# ------------------------------------------------------------
log "Verifying Rspamd service"

systemctl is-active --quiet rspamd || {
    log "Rspamd failed to start"
    exit 1
}

log "Rspamd configured successfully"

echo "rspamd_configured=true"
echo "mail_domain=${MAIL_DOMAIN}"
echo "mail_hostname=${MAIL_HOSTNAME}"