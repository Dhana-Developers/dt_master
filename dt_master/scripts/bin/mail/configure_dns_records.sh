#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# Runtime bootstrap
# ------------------------------------------------------------
source "${SCRIPT_LIB_DIR}/runtime.sh"
source "${SCRIPT_LIB_DIR}/common.sh"

require_root

log "Preparing DNS records"

# ------------------------------------------------------------
# Required environment
# ------------------------------------------------------------
: "${MAIL_DOMAIN:?MAIL_DOMAIN not set}"
: "${MAIL_HOSTNAME:?MAIL_HOSTNAME not set}"
: "${MAIL_IP:?MAIL_IP not set}"

# ------------------------------------------------------------
# Derived values
# ------------------------------------------------------------
MAIL_SUBDOMAIN=$(echo "$MAIL_HOSTNAME" | cut -d'.' -f1)

# ------------------------------------------------------------
# DNS output
# ------------------------------------------------------------

echo
echo "======================================================"
echo "DNS RECORDS REQUIRED FOR MAIL SERVER"
echo "======================================================"
echo

# ------------------------------------------------------------
# A RECORD
# ------------------------------------------------------------
echo "--------------------------------------"
echo "A RECORD"
echo "--------------------------------------"

echo "Type"
echo "A"
echo

echo "Name"
echo "${MAIL_SUBDOMAIN}"
echo

echo "Content"
echo "${MAIL_IP}"
echo

# ------------------------------------------------------------
# MX RECORD
# ------------------------------------------------------------
echo "--------------------------------------"
echo "MX RECORD"
echo "--------------------------------------"

echo "Type"
echo "MX"
echo

echo "Name"
echo "@"
echo

echo "Content"
echo "${MAIL_HOSTNAME}"
echo

echo "Priority"
echo "10"
echo

# ------------------------------------------------------------
# SPF RECORD
# ------------------------------------------------------------
echo "--------------------------------------"
echo "SPF RECORD"
echo "--------------------------------------"

echo "Type"
echo "TXT"
echo

echo "Name"
echo "@"
echo

echo "Content"
echo "\"v=spf1 mx a ip4:${MAIL_IP} ~all\""
echo

# ------------------------------------------------------------
# DMARC RECORD
# ------------------------------------------------------------
echo "--------------------------------------"
echo "DMARC RECORD"
echo "--------------------------------------"

echo "Type"
echo "TXT"
echo

echo "Name"
echo "_dmarc"
echo

echo "Content"
echo "\"v=DMARC1; p=quarantine; rua=mailto:postmaster@${MAIL_DOMAIN}; ruf=mailto:postmaster@${MAIL_DOMAIN}; fo=1\""
echo

echo "======================================================"

log "DNS configuration output generated"

echo "dns_records_generated=true"
echo "mail_domain=${MAIL_DOMAIN}"
echo "mail_hostname=${MAIL_HOSTNAME}"