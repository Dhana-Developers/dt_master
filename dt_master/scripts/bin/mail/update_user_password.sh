#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# Runtime bootstrap
# ------------------------------------------------------------
source "${SCRIPT_LIB_DIR}/runtime.sh"
source "${SCRIPT_LIB_DIR}/common.sh"

require_root

log "Updating virtual mail user password"

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

# ------------------------------------------------------------
# Check if mailbox exists
# ------------------------------------------------------------
log "Checking if mailbox exists"

USER_EXISTS=$(mysql \
  -u"${MYSQL_ROOT_USER}" \
  -p"${MYSQL_ROOT_PASSWORD}" \
  "${MAIL_DB}" \
  -N -e "SELECT COUNT(*) FROM virtual_users WHERE email='${EMAIL}';")

if [[ "$USER_EXISTS" -eq 0 ]]; then
    log "Mailbox does not exist: ${EMAIL}"
    echo "mail_user_exists=false"
    exit 1
fi

# ------------------------------------------------------------
# Generate password hash
# ------------------------------------------------------------
log "Generating password hash"

HASH=$(doveadm pw -s SHA512-CRYPT -p "${MAIL_PASSWORD}")

# ------------------------------------------------------------
# Update password in database
# ------------------------------------------------------------
log "Updating password for ${EMAIL}"

mysql -u"${MYSQL_ROOT_USER}" -p"${MYSQL_ROOT_PASSWORD}" "${MAIL_DB}" <<SQL
UPDATE virtual_users
SET password='${HASH}'
WHERE email='${EMAIL}';
SQL

log "Password updated successfully"

echo "mail_user_password_updated=true"
echo "email=${EMAIL}"