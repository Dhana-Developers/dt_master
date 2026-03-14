#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# Runtime bootstrap
# ------------------------------------------------------------
source "${SCRIPT_LIB_DIR}/runtime.sh"
source "${SCRIPT_LIB_DIR}/common.sh"

require_root

log "Creating virtual mail user"

# ------------------------------------------------------------
# Required environment
# ------------------------------------------------------------
: "${MAIL_USER:?MAIL_USER not set}"
: "${MAIL_PASSWORD:?MAIL_PASSWORD not set}"
: "${MAIL_DOMAIN:?MAIL_DOMAIN not set}"
: "${MYSQL_ROOT_USER:?MYSQL_ROOT_USER not set}"
: "${MYSQL_ROOT_PASSWORD:?MYSQL_ROOT_PASSWORD not set}"

MAIL_DB="mailserver"

EMAIL="${MAIL_USER}@${MAIL_DOMAIN}"
MAIL_DIR="/var/mail/vhosts/${MAIL_DOMAIN}/${MAIL_USER}"

# ------------------------------------------------------------
# Ensure domain directory exists
# ------------------------------------------------------------
log "Ensuring domain mail directory exists"

mkdir -p "/var/mail/vhosts/${MAIL_DOMAIN}"

# ------------------------------------------------------------
# Generate password hash
# ------------------------------------------------------------
log "Generating password hash"

HASH=$(doveadm pw -s SHA512-CRYPT -p "${MAIL_PASSWORD}")

# ------------------------------------------------------------
# Ensure database entry exists
# ------------------------------------------------------------
log "Ensuring database mailbox entry"

USER_EXISTS=$(mysql \
    -u"${MYSQL_ROOT_USER}" \
    -p"${MYSQL_ROOT_PASSWORD}" \
    -N \
    -e "SELECT COUNT(*) FROM ${MAIL_DB}.virtual_users WHERE email='${EMAIL}'")

if [[ "$USER_EXISTS" -eq 0 ]]; then

    log "Creating database user ${EMAIL}"

    mysql -u"${MYSQL_ROOT_USER}" -p"${MYSQL_ROOT_PASSWORD}" <<SQL
INSERT INTO ${MAIL_DB}.virtual_users (email,password)
VALUES ('${EMAIL}','${HASH}');
SQL

else

    log "User already exists, updating password"

    mysql -u"${MYSQL_ROOT_USER}" -p"${MYSQL_ROOT_PASSWORD}" <<SQL
UPDATE ${MAIL_DB}.virtual_users
SET password='${HASH}'
WHERE email='${EMAIL}';
SQL

fi

# ------------------------------------------------------------
# Ensure mailbox directory exists
# ------------------------------------------------------------
if [[ -d "${MAIL_DIR}" ]]; then
    log "Mailbox directory already exists"
else
    log "Creating mailbox directory"
    mkdir -p "${MAIL_DIR}"
fi

# ------------------------------------------------------------
# Ensure Maildir structure exists
# ------------------------------------------------------------
if [[ -d "${MAIL_DIR}/cur" && -d "${MAIL_DIR}/new" && -d "${MAIL_DIR}/tmp" ]]; then
    log "Maildir structure already exists"
else
    log "Creating Maildir structure"
    maildirmake.dovecot "${MAIL_DIR}"
fi

# ------------------------------------------------------------
# Fix ownership and permissions
# ------------------------------------------------------------
log "Fixing mailbox permissions"

chown -R vmail:mail "${MAIL_DIR}"
chmod -R 700 "${MAIL_DIR}"

# ------------------------------------------------------------
# Display mailbox information
# ------------------------------------------------------------
log "Listing mailbox directory"

ls -la "${MAIL_DIR}"

log "Mail user ready"

echo "mail_user_created=true"
echo "email=${EMAIL}"
echo "mail_dir=${MAIL_DIR}"