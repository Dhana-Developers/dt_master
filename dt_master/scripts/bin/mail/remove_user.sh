#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# Runtime bootstrap
# ------------------------------------------------------------
source "${SCRIPT_LIB_DIR}/runtime.sh"
source "${SCRIPT_LIB_DIR}/common.sh"

require_root

log "Removing virtual mail user"

# ------------------------------------------------------------
# Required environment
# ------------------------------------------------------------
: "${MAIL_USER:?MAIL_USER not set}"
: "${MAIL_DOMAIN:?MAIL_DOMAIN not set}"
: "${MYSQL_ROOT_USER:?MYSQL_ROOT_USER not set}"
: "${MYSQL_ROOT_PASSWORD:?MYSQL_ROOT_PASSWORD not set}"

MAIL_DB="mailserver"

EMAIL="${MAIL_USER}@${MAIL_DOMAIN}"
MAIL_DIR="/var/mail/vhosts/${MAIL_DOMAIN}/${MAIL_USER}"

# ------------------------------------------------------------
# Check if user exists in database
# ------------------------------------------------------------
log "Checking if mailbox exists in database"

USER_EXISTS=$(mysql \
    -u"${MYSQL_ROOT_USER}" \
    -p"${MYSQL_ROOT_PASSWORD}" \
    -N \
    -e "SELECT COUNT(*) FROM ${MAIL_DB}.virtual_users WHERE email='${EMAIL}'")

if [[ "$USER_EXISTS" -eq 0 ]]; then
    log "User does not exist in database: ${EMAIL}"
    echo "mail_user_exists=false"
    exit 1
fi

# ------------------------------------------------------------
# Delete user from database
# ------------------------------------------------------------
log "Removing user from database"

mysql -u"${MYSQL_ROOT_USER}" -p"${MYSQL_ROOT_PASSWORD}" <<SQL
DELETE FROM ${MAIL_DB}.virtual_users
WHERE email='${EMAIL}';
SQL

# ------------------------------------------------------------
# Remove mailbox directory
# ------------------------------------------------------------
if [[ -d "${MAIL_DIR}" ]]; then
    log "Removing mailbox directory ${MAIL_DIR}"
    rm -rf "${MAIL_DIR}"
else
    log "Mailbox directory not found"
fi

# ------------------------------------------------------------
# Verify deletion
# ------------------------------------------------------------
USER_EXISTS=$(mysql \
    -u"${MYSQL_ROOT_USER}" \
    -p"${MYSQL_ROOT_PASSWORD}" \
    -N \
    -e "SELECT COUNT(*) FROM ${MAIL_DB}.virtual_users WHERE email='${EMAIL}'")

if [[ "$USER_EXISTS" -eq 0 ]]; then
    log "Mailbox deleted successfully"

    echo "mail_user_deleted=true"
    echo "email=${EMAIL}"
else
    log "Failed to delete mailbox from database"

    echo "mail_user_deleted=false"
    exit 1
fi