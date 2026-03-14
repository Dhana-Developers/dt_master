#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# Runtime bootstrap
# ------------------------------------------------------------
source "${SCRIPT_LIB_DIR}/runtime.sh"
source "${SCRIPT_LIB_DIR}/common.sh"

require_root

log "Listing virtual mail users"

# ------------------------------------------------------------
# Required environment
# ------------------------------------------------------------
: "${MAIL_DOMAIN:?MAIL_DOMAIN not set}"
: "${MYSQL_ROOT_USER:?MYSQL_ROOT_USER not set}"
: "${MYSQL_ROOT_PASSWORD:?MYSQL_ROOT_PASSWORD not set}"

MAIL_DB="mailserver"

# ------------------------------------------------------------
# Query database
# ------------------------------------------------------------
log "Querying database for users in domain ${MAIL_DOMAIN}"

mysql \
  -u"${MYSQL_ROOT_USER}" \
  -p"${MYSQL_ROOT_PASSWORD}" \
  "${MAIL_DB}" \
  -N -e "
SELECT email
FROM virtual_users
WHERE email LIKE '%@${MAIL_DOMAIN}'
ORDER BY email;
"

log "User listing completed"

echo "mail_users_listed=true"
echo "mail_domain=${MAIL_DOMAIN}"