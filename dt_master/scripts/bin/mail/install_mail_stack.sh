#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# Runtime bootstrap
# ------------------------------------------------------------
source "${SCRIPT_LIB_DIR}/runtime.sh"
source "${SCRIPT_LIB_DIR}/common.sh"

require_root

log "Starting mail stack installation"

# ------------------------------------------------------------
# Required environment
# ------------------------------------------------------------
: "${MAIL_DOMAIN:?MAIL_DOMAIN not set}"
: "${MAIL_HOSTNAME:?MAIL_HOSTNAME not set}"
: "${MAIL_IP:?MAIL_IP not set}"

# ------------------------------------------------------------
# Non-interactive APT
# ------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive

log "Updating package index"
apt-get update -y

# ------------------------------------------------------------
# Required packages
# ------------------------------------------------------------
PACKAGES=(
    postfix
    postfix-mysql
    dovecot-core
    dovecot-imapd
    dovecot-lmtpd
    dovecot-mysql
    rspamd
    redis-server
    opendkim
    opendkim-tools
    certbot
    mailutils
    dnsutils
)

log "Installing mail packages"

apt-get install -y "${PACKAGES[@]}"

# ------------------------------------------------------------
# Ensure services exist
# ------------------------------------------------------------
SERVICES=(
    postfix
    dovecot
    rspamd
    opendkim
    redis-server
)

for svc in "${SERVICES[@]}"; do
    log "Enabling service $svc"
    systemctl enable "$svc"
done

# ------------------------------------------------------------
# Ensure directories
# ------------------------------------------------------------
log "Preparing mail directories"

mkdir -p /var/mail
mkdir -p /var/spool/postfix
mkdir -p /etc/opendkim/keys

chmod 755 /var/mail
chmod 755 /etc/opendkim/keys

# ------------------------------------------------------------
# Basic hostname sanity
# ------------------------------------------------------------
CURRENT_HOST=$(hostname)

if [[ "$CURRENT_HOST" != "$MAIL_HOSTNAME" ]]; then
    log "Setting system hostname to $MAIL_HOSTNAME"
    hostnamectl set-hostname "$MAIL_HOSTNAME"
fi

# ------------------------------------------------------------
# Install completed
# ------------------------------------------------------------
log "Mail stack packages installed successfully"

echo "mail_stack_installed=true"
echo "mail_domain=${MAIL_DOMAIN}"
echo "mail_hostname=${MAIL_HOSTNAME}"
echo "mail_ip=${MAIL_IP}"