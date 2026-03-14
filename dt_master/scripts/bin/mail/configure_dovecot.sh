#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# Runtime bootstrap
# ------------------------------------------------------------
source "${SCRIPT_LIB_DIR}/runtime.sh"
source "${SCRIPT_LIB_DIR}/common.sh"

require_root

log "Configuring Dovecot"

# ------------------------------------------------------------
# Required environment
# ------------------------------------------------------------
: "${MAIL_DOMAIN:?MAIL_DOMAIN not set}"
: "${MAIL_HOSTNAME:?MAIL_HOSTNAME not set}"
: "${MYSQL_ROOT_USER:?MYSQL_ROOT_USER not set}"
: "${MYSQL_ROOT_PASSWORD:?MYSQL_ROOT_PASSWORD not set}"

# ------------------------------------------------------------
# Paths
# ------------------------------------------------------------
DOVECOT_DIR="/etc/dovecot"
CONF_D="${DOVECOT_DIR}/conf.d"

TLS_CERT="/etc/letsencrypt/live/${MAIL_HOSTNAME}/fullchain.pem"
TLS_KEY="/etc/letsencrypt/live/${MAIL_HOSTNAME}/privkey.pem"

MAIL_DB="mailserver"

# ------------------------------------------------------------
# Prepare mail database
# ------------------------------------------------------------
log "Preparing mail database"

mysql -u"${MYSQL_ROOT_USER}" -p"${MYSQL_ROOT_PASSWORD}" -e "SELECT 1" >/dev/null

mysql -u"${MYSQL_ROOT_USER}" -p"${MYSQL_ROOT_PASSWORD}" <<SQL
CREATE DATABASE IF NOT EXISTS ${MAIL_DB};
SQL

mysql -u"${MYSQL_ROOT_USER}" -p"${MYSQL_ROOT_PASSWORD}" ${MAIL_DB} <<SQL
CREATE TABLE IF NOT EXISTS virtual_users (
    id INT AUTO_INCREMENT PRIMARY KEY,
    email VARCHAR(255) UNIQUE NOT NULL,
    password VARCHAR(255) NOT NULL
);
SQL

log "Mail database ready"

# ------------------------------------------------------------
# Ensure vmail system user exists
# ------------------------------------------------------------
log "Ensuring vmail user exists"

if ! id vmail >/dev/null 2>&1; then
    useradd -r -u 5000 -g mail -d /var/mail vmail
fi

# ------------------------------------------------------------
# Protocols
# ------------------------------------------------------------
log "Configuring mail protocols"

cat > "${CONF_D}/10-mail.conf" <<EOF
mail_location = maildir:/var/mail/vhosts/%d/%n

mail_uid = vmail
mail_gid = mail

namespace inbox {
  inbox = yes
}
EOF

# ------------------------------------------------------------
# Authentication (SQL)
# ------------------------------------------------------------
log "Configuring SQL authentication"

cat > "${CONF_D}/10-auth.conf" <<EOF
disable_plaintext_auth = yes
auth_mechanisms = plain login

!include auth-sql.conf.ext
EOF

cat > "${CONF_D}/auth-sql.conf.ext" <<EOF
passdb {
  driver = sql
  args = /etc/dovecot/dovecot-sql.conf.ext
}

userdb {
  driver = static
  args = uid=vmail gid=mail home=/var/mail/vhosts/%d/%n
}
EOF

cat > "/etc/dovecot/dovecot-sql.conf.ext" <<EOF
driver = mysql

connect = host=127.0.0.1 dbname=${MAIL_DB} user=${MYSQL_ROOT_USER} password=${MYSQL_ROOT_PASSWORD}

default_pass_scheme = SHA512-CRYPT

password_query = SELECT email as user, password FROM virtual_users WHERE email='%u';
EOF

# ------------------------------------------------------------
# LMTP for Postfix delivery
# ------------------------------------------------------------
log "Configuring LMTP"

cat > "${CONF_D}/20-lmtp.conf" <<EOF
protocol lmtp {
  postmaster_address = postmaster@${MAIL_DOMAIN}
}
EOF

# ------------------------------------------------------------
# IMAP
# ------------------------------------------------------------
log "Configuring IMAP"

cat > "${CONF_D}/20-imap.conf" <<EOF
protocol imap {
  mail_plugins = \$mail_plugins
}
EOF

# ------------------------------------------------------------
# Mailbox settings
# ------------------------------------------------------------
log "Configuring mailboxes"

cat > "${CONF_D}/15-mailboxes.conf" <<EOF
namespace inbox {
  inbox = yes

  mailbox Drafts {
    special_use = \\Drafts
  }

  mailbox Sent {
    special_use = \\Sent
  }

  mailbox Trash {
    special_use = \\Trash
  }

  mailbox Junk {
    special_use = \\Junk
  }
}
EOF

# ------------------------------------------------------------
# Master services
# ------------------------------------------------------------
log "Configuring services"

cat > "${CONF_D}/10-master.conf" <<EOF
service imap-login {
  inet_listener imap {
    port = 143
  }

  inet_listener imaps {
    port = 993
    ssl = yes
  }
}

service lmtp {
  unix_listener /var/spool/postfix/private/dovecot-lmtp {
    mode = 0600
    user = postfix
    group = postfix
  }
}

service auth {
  unix_listener /var/spool/postfix/private/auth {
    mode = 0660
    user = postfix
    group = postfix
  }
}
EOF

# ------------------------------------------------------------
# TLS configuration
# ------------------------------------------------------------
log "Configuring TLS"

if [[ ! -f "$TLS_CERT" || ! -f "$TLS_KEY" ]]; then

    log "TLS certificate not found, attempting certbot"

    PORT80_SERVICE=$(ss -lntp 2>/dev/null | awk '/:80 / {print $NF}' | sed -E 's/.*users:\(\("([^"]+)".*/\1/' | head -n1 || true)

    STOPPED_SERVICE=""

    if [[ -n "$PORT80_SERVICE" ]]; then
        systemctl stop "$PORT80_SERVICE" || true
        STOPPED_SERVICE="$PORT80_SERVICE"
    fi

    trap 'if [[ -n "$STOPPED_SERVICE" ]]; then systemctl start "$STOPPED_SERVICE"; fi' EXIT

    certbot certonly \
        --standalone \
        --non-interactive \
        --agree-tos \
        --register-unsafely-without-email \
        -d "${MAIL_HOSTNAME}" || true

    if [[ -n "$STOPPED_SERVICE" ]]; then
        systemctl start "$STOPPED_SERVICE" || true
        STOPPED_SERVICE=""
    fi

    trap - EXIT
fi

if [[ -f "$TLS_CERT" && -f "$TLS_KEY" ]]; then

cat > "${CONF_D}/10-ssl.conf" <<EOF
ssl = required
ssl_cert = <${TLS_CERT}
ssl_key = <${TLS_KEY}
ssl_min_protocol = TLSv1.2
ssl_prefer_server_ciphers = yes
EOF

log "TLS enabled"

else

cat > "${CONF_D}/10-ssl.conf" <<EOF
ssl = no
EOF

log "TLS certificate not available, IMAPS disabled"

fi

# ------------------------------------------------------------
# Logging
# ------------------------------------------------------------
log "Configuring logging"

cat > "${CONF_D}/10-logging.conf" <<EOF
log_path = /var/log/dovecot.log
info_log_path = /var/log/dovecot-info.log
EOF

# ------------------------------------------------------------
# Mail storage
# ------------------------------------------------------------
log "Preparing mail directories"

mkdir -p /var/mail/vhosts
chown -R vmail:mail /var/mail
chmod -R 750 /var/mail/vhosts

# ------------------------------------------------------------
# Restart Dovecot
# ------------------------------------------------------------
log "Restarting Dovecot"

systemctl enable dovecot
systemctl restart dovecot

# ------------------------------------------------------------
# Verify configuration
# ------------------------------------------------------------
log "Verifying Dovecot configuration"

dovecot -n

log "Dovecot configured successfully"

echo "dovecot_configured=true"
echo "mail_domain=${MAIL_DOMAIN}"
echo "mail_hostname=${MAIL_HOSTNAME}"