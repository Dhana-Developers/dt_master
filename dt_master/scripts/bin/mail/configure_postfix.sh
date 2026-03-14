#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# Runtime bootstrap
# ------------------------------------------------------------
source "${SCRIPT_LIB_DIR}/runtime.sh"
source "${SCRIPT_LIB_DIR}/common.sh"

require_root

log "Configuring Postfix"

# ------------------------------------------------------------
# Required environment
# ------------------------------------------------------------
: "${MAIL_DOMAIN:?MAIL_DOMAIN not set}"
: "${MAIL_HOSTNAME:?MAIL_HOSTNAME not set}"
: "${MAIL_IP:?MAIL_IP not set}"
: "${DKIM_SELECTOR:?DKIM_SELECTOR not set}"
: "${MYSQL_ROOT_USER:?MYSQL_ROOT_USER not set}"
: "${MYSQL_ROOT_PASSWORD:?MYSQL_ROOT_PASSWORD not set}"

# ------------------------------------------------------------
# Paths
# ------------------------------------------------------------
POSTFIX_MAIN="/etc/postfix/main.cf"
POSTFIX_MASTER="/etc/postfix/master.cf"
POSTFIX_SQL_DIR="/etc/postfix/sql"

TLS_CERT="/etc/letsencrypt/live/${MAIL_HOSTNAME}/fullchain.pem"
TLS_KEY="/etc/letsencrypt/live/${MAIL_HOSTNAME}/privkey.pem"

MAIL_DB="mailserver"

# ------------------------------------------------------------
# Set hostname and mailname
# ------------------------------------------------------------
log "Setting Postfix hostname"

postconf -e "myhostname = ${MAIL_HOSTNAME}"
postconf -e "mydomain = ${MAIL_DOMAIN}"
postconf -e "myorigin = \$mydomain"

# ------------------------------------------------------------
# Network settings
# ------------------------------------------------------------
log "Configuring network interfaces"

postconf -e "inet_interfaces = all"
postconf -e "inet_protocols = ipv4"
postconf -e "mynetworks = 127.0.0.0/8"

# ------------------------------------------------------------
# Mail routing
# ------------------------------------------------------------
log "Configuring mail routing"

postconf -e "mydestination = localhost.\$mydomain, localhost"
postconf -e "relay_domains ="

# ------------------------------------------------------------
# Prepare SQL lookup directory
# ------------------------------------------------------------
log "Preparing Postfix SQL lookup configuration"

mkdir -p "${POSTFIX_SQL_DIR}"

cat > "${POSTFIX_SQL_DIR}/virtual_domains.cf" <<EOF
user=${MYSQL_ROOT_USER}
password=${MYSQL_ROOT_PASSWORD}
hosts=127.0.0.1
dbname=${MAIL_DB}
query=SELECT 1 FROM virtual_users WHERE email LIKE '%@%s' LIMIT 1;
EOF

cat > "${POSTFIX_SQL_DIR}/virtual_users.cf" <<EOF
user=${MYSQL_ROOT_USER}
password=${MYSQL_ROOT_PASSWORD}
hosts=127.0.0.1
dbname=${MAIL_DB}
query=SELECT 1 FROM virtual_users WHERE email='%s';
EOF

chmod 640 ${POSTFIX_SQL_DIR}/*.cf
chown root:postfix ${POSTFIX_SQL_DIR}/*.cf

# ------------------------------------------------------------
# Virtual mailbox configuration
# ------------------------------------------------------------
log "Configuring virtual mailbox system"

postconf -e "virtual_mailbox_domains = mysql:/etc/postfix/sql/virtual_domains.cf"
postconf -e "virtual_mailbox_maps = mysql:/etc/postfix/sql/virtual_users.cf"
postconf -e "virtual_alias_maps = mysql:/etc/postfix/sql/virtual_users.cf"

postconf -e "virtual_mailbox_base = /var/mail/vhosts"

postconf -e "virtual_uid_maps = static:5000"
postconf -e "virtual_gid_maps = static:8"

postconf -e "virtual_transport = lmtp:unix:private/dovecot-lmtp"

# ------------------------------------------------------------
# TLS configuration
# ------------------------------------------------------------
log "Configuring TLS"

if [[ -f "$TLS_CERT" ]]; then

    postconf -e "smtpd_tls_cert_file = ${TLS_CERT}"
    postconf -e "smtpd_tls_key_file = ${TLS_KEY}"

    postconf -e "smtpd_tls_security_level = may"
    postconf -e "smtp_tls_security_level = may"

    postconf -e "smtpd_tls_protocols = !SSLv2,!SSLv3"
    postconf -e "smtp_tls_protocols = !SSLv2,!SSLv3"

    log "TLS configured"

else
    log "TLS certificate not found yet, skipping TLS configuration"
fi

# ------------------------------------------------------------
# Submission port (587)
# ------------------------------------------------------------
log "Ensuring submission service is enabled"

if ! grep -q "^submission" "$POSTFIX_MASTER"; then
cat >> "$POSTFIX_MASTER" <<EOF

submission inet n       -       y       -       -       smtpd
  -o syslog_name=postfix/submission
  -o smtpd_tls_security_level=encrypt
  -o smtpd_sasl_auth_enable=yes
  -o smtpd_client_restrictions=permit_sasl_authenticated,reject
  -o smtpd_recipient_restrictions=permit_sasl_authenticated,reject
EOF
fi

# ------------------------------------------------------------
# SMTP authentication (Dovecot)
# ------------------------------------------------------------
log "Configuring SMTP authentication"

postconf -e "smtpd_sasl_type = dovecot"
postconf -e "smtpd_sasl_path = private/auth"
postconf -e "smtpd_sasl_auth_enable = yes"
postconf -e "smtpd_sasl_security_options = noanonymous"

# ------------------------------------------------------------
# Rspamd integration
# ------------------------------------------------------------
log "Configuring Rspamd milter"

postconf -e "milter_protocol = 6"
postconf -e "milter_default_action = accept"

postconf -e "smtpd_milters = inet:localhost:11332"
postconf -e "non_smtpd_milters = inet:localhost:11332"

# ------------------------------------------------------------
# Prepare OpenDKIM socket for Postfix
# ------------------------------------------------------------
log "Preparing OpenDKIM socket directory"

OPENDKIM_CHROOT_DIR="/var/spool/postfix/opendkim"

mkdir -p "$OPENDKIM_CHROOT_DIR"
chown opendkim:opendkim "$OPENDKIM_CHROOT_DIR"
chmod 750 "$OPENDKIM_CHROOT_DIR"

# ------------------------------------------------------------
# Configure OpenDKIM socket
# ------------------------------------------------------------
log "Configuring OpenDKIM socket"

OPENDKIM_CONF="/etc/opendkim.conf"

if grep -q "^Socket" "$OPENDKIM_CONF"; then
    sed -i 's|^Socket.*|Socket local:/var/spool/postfix/opendkim/opendkim.sock|' "$OPENDKIM_CONF"
else
    echo "Socket local:/var/spool/postfix/opendkim/opendkim.sock" >> "$OPENDKIM_CONF"
fi

systemctl restart opendkim

# ------------------------------------------------------------
# OpenDKIM integration
# ------------------------------------------------------------
log "Configuring OpenDKIM milter"

postconf -e "smtpd_milters=inet:localhost:11332,unix:/opendkim/opendkim.sock"
postconf -e "non_smtpd_milters=inet:localhost:11332,unix:/opendkim/opendkim.sock"

# ------------------------------------------------------------
# Allow Postfix access to OpenDKIM socket
# ------------------------------------------------------------
log "Granting Postfix access to OpenDKIM socket"

if ! id -nG postfix | grep -qw opendkim; then
    usermod -aG opendkim postfix
    log "Postfix added to opendkim group"
else
    log "Postfix already in opendkim group"
fi

# ------------------------------------------------------------
# Security settings
# ------------------------------------------------------------
log "Applying security restrictions"

postconf -e "smtpd_helo_required = yes"

postconf -e "smtpd_helo_restrictions = permit_mynetworks,reject_invalid_helo_hostname,reject_non_fqdn_helo_hostname"

postconf -e "smtpd_recipient_restrictions = permit_mynetworks,permit_sasl_authenticated,reject_unauth_destination"

# ------------------------------------------------------------
# Mail size
# ------------------------------------------------------------
postconf -e "message_size_limit = 52428800"

# ------------------------------------------------------------
# Reload postfix
# ------------------------------------------------------------
log "Restarting Postfix"

systemctl restart postfix

# ------------------------------------------------------------
# Verify postfix
# ------------------------------------------------------------
log "Verifying Postfix configuration"

postfix check

log "Postfix configured successfully"

echo "postfix_configured=true"
echo "mail_domain=${MAIL_DOMAIN}"
echo "mail_hostname=${MAIL_HOSTNAME}"