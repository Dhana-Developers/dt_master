#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# Runtime bootstrap
# ------------------------------------------------------------
source "${SCRIPT_LIB_DIR}/runtime.sh"
source "${SCRIPT_LIB_DIR}/common.sh"

require_root

log "Verifying mail server"

# ------------------------------------------------------------
# Required environment
# ------------------------------------------------------------
: "${MAIL_DOMAIN:?MAIL_DOMAIN not set}"
: "${MAIL_HOSTNAME:?MAIL_HOSTNAME not set}"
: "${MAIL_IP:?MAIL_IP not set}"
: "${DKIM_SELECTOR:?DKIM_SELECTOR not set}"

# ------------------------------------------------------------
# DNS checks
# ------------------------------------------------------------
log "Checking DNS records"

MX_RECORD=$(dig +short MX "${MAIL_DOMAIN}" | awk '{print $2}' | sed 's/\.$//')
DKIM_RECORD=$(dig +short TXT "${DKIM_SELECTOR}._domainkey.${MAIL_DOMAIN}")
SPF_RECORD=$(dig +short TXT "${MAIL_DOMAIN}" | grep spf || true)

if [[ -z "$MX_RECORD" ]]; then
    log "MX record not found"
    exit 1
fi

if [[ "$MX_RECORD" != "$MAIL_HOSTNAME" ]]; then
    log "MX record does not match expected hostname"
    exit 1
fi

if [[ -z "$DKIM_RECORD" ]]; then
    log "DKIM record not found"
    exit 1
fi

if [[ -z "$SPF_RECORD" ]]; then
    log "SPF record not found"
    exit 1
fi

log "DNS checks passed"

# ------------------------------------------------------------
# Service checks
# ------------------------------------------------------------
log "Checking services"

SERVICES=(
    postfix
    dovecot
    rspamd
    opendkim
)

for svc in "${SERVICES[@]}"; do
    if ! systemctl is-active --quiet "$svc"; then
        log "Service $svc is not running"
        exit 1
    fi
done

log "All services running"

# ------------------------------------------------------------
# Port checks
# ------------------------------------------------------------
log "Checking required ports"

PORTS=(
    25
    587
    143
    993
)

for port in "${PORTS[@]}"; do
    if ! ss -lnt | awk '{print $4}' | grep -q ":$port$"; then
        log "Port $port not listening"
        exit 1
    fi
done

log "Required ports are open"

# ------------------------------------------------------------
# SMTP connectivity test
# ------------------------------------------------------------
log "Testing SMTP connectivity"

if ! timeout 5 bash -c "echo QUIT | nc localhost 25" >/dev/null 2>&1; then
    log "SMTP test failed"
    exit 1
fi

log "SMTP responding"

# ------------------------------------------------------------
# DKIM test (basic)
# ------------------------------------------------------------
log "Checking DKIM key"

KEY_FILE="/etc/opendkim/keys/${MAIL_DOMAIN}/${DKIM_SELECTOR}.private"

if [[ ! -f "$KEY_FILE" ]]; then
    log "DKIM private key missing"
    exit 1
fi

log "DKIM key present"

# ------------------------------------------------------------
# Rspamd test
# ------------------------------------------------------------
log "Checking Rspamd"

if ! rspamadm configtest >/dev/null 2>&1; then
    log "Rspamd configuration invalid"
    exit 1
fi

log "Rspamd configuration valid"

# ------------------------------------------------------------
# Summary
# ------------------------------------------------------------
log "Mail server verification successful"

echo "mail_server_verified=true"
echo "mail_domain=${MAIL_DOMAIN}"
echo "mail_hostname=${MAIL_HOSTNAME}"