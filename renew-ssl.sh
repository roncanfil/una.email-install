#!/bin/bash

# Unified SSL certificate renewal script for Una.Email
# - Run manually: ./renew-ssl.sh (obtains or renews certificate)
# - Run via cron:  ./renew-ssl.sh --cron (quiet renewal, only acts when needed)

set -e

cd "$(dirname "$0")"

# Check for --cron flag
CRON_MODE=false
if [[ "$1" == "--cron" ]]; then
    CRON_MODE=true
fi

# Load environment variables
if [ ! -f .env ]; then
    echo "❌ Error: .env file not found. Please run install.sh first or create .env manually."
    exit 1
fi

source .env

if [ -z "${DOMAIN:-}" ]; then
    echo "❌ Error: DOMAIN not set in .env file"
    exit 1
fi

# One certificate, two names.
#
#   WEB_HOSTNAME   the webmail UI. First in the -d list, which makes it the
#                  lineage name, which makes it the live/ directory -- and
#                  Nginx's ssl_certificate path is that directory, literally.
#   SMTP_HOSTNAME  what Postfix announces in HELO and what the MX points at.
#                  It has to be on this certificate, because the same file is
#                  copied to /etc/postfix/tls and served on port 25. A
#                  certificate that only names the webmail host makes every
#                  sender doing MTA-STS or strict verification fail the name
#                  check -- silently, since opportunistic TLS does not care.
#
# MAIL_SUBDOMAIN is the old name for WEB_SUBDOMAIN: it always meant the web
# host. Read as a fallback so an .env written before the split still works.
WEB_SUBDOMAIN="${WEB_SUBDOMAIN:-${MAIL_SUBDOMAIN:-webmail}}"
SMTP_SUBDOMAIN="${SMTP_SUBDOMAIN:-mail}"
WEB_HOSTNAME="${WEB_SUBDOMAIN}.${DOMAIN}"
SMTP_HOSTNAME="${SMTP_SUBDOMAIN}.${DOMAIN}"

# Answering both prompts the same is allowed, and then there is one name to ask
# for. Passing -d twice for the same name makes certbot error out.
CERT_ARGS=(-d "$WEB_HOSTNAME")
CERT_NAMES="$WEB_HOSTNAME"
if [ "$SMTP_HOSTNAME" != "$WEB_HOSTNAME" ]; then
    CERT_ARGS+=(-d "$SMTP_HOSTNAME")
    CERT_NAMES="$WEB_HOSTNAME, $SMTP_HOSTNAME"
fi

CERT_PATH="./letsencrypt/etc/live/${WEB_HOSTNAME}/cert.pem"

# Does the certificate on disk actually name this host? Exact match against the
# SAN list -- a substring test would accept mail.example.com for a certificate
# naming mail.example.com.au.
cert_covers() {
    [ -f "$CERT_PATH" ] || return 1
    openssl x509 -in "$CERT_PATH" -noout -ext subjectAltName 2>/dev/null \
        | tr ',' '\n' \
        | sed 's/^[[:space:]]*DNS://; s/[[:space:]]*$//' \
        | grep -Fxq "$1"
}

# Function to sync certificate to Postfix
sync_to_postfix() {
    echo "Syncing certificate to Postfix..."
    docker compose exec -T postfix sh -lc 'mkdir -p /etc/postfix/tls; if [ -f "/etc/letsencrypt/live/'"$WEB_HOSTNAME"'/fullchain.pem" ] && [ -f "/etc/letsencrypt/live/'"$WEB_HOSTNAME"'/privkey.pem" ]; then cp -f "/etc/letsencrypt/live/'"$WEB_HOSTNAME"'/fullchain.pem" /etc/postfix/tls/fullchain.pem && cp -f "/etc/letsencrypt/live/'"$WEB_HOSTNAME"'/privkey.pem" /etc/postfix/tls/privkey.pem && chown root:postfix /etc/postfix/tls/privkey.pem && chmod 640 /etc/postfix/tls/privkey.pem; fi; postfix reload' || true
}

# Function to restart Nginx
restart_nginx() {
    echo "Restarting Nginx to apply new certificate..."
    docker compose restart nginx
}

# Check if certificate exists
CERT_EXISTS=false
if docker compose run --rm certbot certificates 2>/dev/null | grep -q "$WEB_HOSTNAME"; then
    CERT_EXISTS=true
fi

if [ "$CERT_EXISTS" = false ]; then
    # No certificate exists — obtain a new one
    echo "📋 No certificate found for $WEB_HOSTNAME. Obtaining a new one..."
    echo "   Names on the certificate: $CERT_NAMES"
    echo ""

    # Clean up any leftover directories
    rm -rf ./letsencrypt/etc/live/$WEB_HOSTNAME 2>/dev/null || true
    rm -rf ./letsencrypt/etc/archive/$WEB_HOSTNAME 2>/dev/null || true
    rm -f ./letsencrypt/etc/renewal/$WEB_HOSTNAME.conf 2>/dev/null || true

    # --cert-name pins the lineage to the web host, so the live/ directory keeps
    # that name even when the -d list changes later (see the --expand branch).
    if ! docker compose run --rm certbot certonly --webroot --webroot-path=/var/www/certbot \
        --register-unsafely-without-email --agree-tos --reuse-key \
        --cert-name "$WEB_HOSTNAME" "${CERT_ARGS[@]}"; then
        echo "❌ SSL certificate request failed"
        echo "ℹ️  Common issues:"
        echo "   - DNS not pointing to this server (BOTH names need an A record)"
        echo "   - Port 80 not accessible"
        echo "   - Rate limiting (wait a few hours)"
        exit 1
    fi

    sync_to_postfix
    restart_nginx

    echo ""
    echo "✅ SSL certificate obtained!"
    echo "🌐 Your website should now be accessible at https://$WEB_HOSTNAME"
elif ! cert_covers "$SMTP_HOSTNAME"; then
    # An existing certificate that predates the split: issued for the web host
    # only, and then copied onto port 25 anyway. Add the SMTP name to the same
    # lineage rather than starting a second one, so Nginx's path does not move
    # and the renewal config stays in one place.
    echo "🔁 Certificate exists but does not cover $SMTP_HOSTNAME — expanding it..."
    echo "   Postfix serves this certificate on port 25 while announcing"
    echo "   $SMTP_HOSTNAME, so that name belongs on it."
    echo ""

    if docker compose run --rm certbot certonly --webroot --webroot-path=/var/www/certbot \
        --register-unsafely-without-email --agree-tos --reuse-key --expand \
        --cert-name "$WEB_HOSTNAME" "${CERT_ARGS[@]}"; then
        sync_to_postfix
        restart_nginx
        echo ""
        echo "✅ Certificate now covers $WEB_HOSTNAME and $SMTP_HOSTNAME"
    else
        echo "❌ Certificate expansion failed"
        echo "ℹ️  $SMTP_HOSTNAME needs an A record pointing here and port 80 reachable."
        echo "   The existing certificate is untouched and still valid."
        # Not fatal in cron mode. The old certificate still works for the web UI
        # and still gives Postfix opportunistic TLS; failing the nightly job
        # outright would turn a name-mismatch into a missed renewal, which is
        # the worse of the two problems.
        if [ "$CRON_MODE" = false ]; then
            exit 1
        fi
    fi
elif [ "$CRON_MODE" = true ]; then
    # Cron mode — quiet renewal
    if docker compose run --rm certbot renew --quiet 2>/dev/null; then
        sync_to_postfix
        restart_nginx
    fi
else
    # Manual renewal
    echo "🔄 Renewing SSL certificate for $WEB_HOSTNAME..."
    if docker compose run --rm certbot renew; then
        echo "✅ Certificate renewal check completed"
        sync_to_postfix
        restart_nginx
        echo "✅ SSL renewal process complete."
    else
        echo "⚠️  Certificate renewal failed"
        exit 1
    fi
fi

# Generate DANE/TLSA record (if certificate exists)
if [ -f "$CERT_PATH" ]; then
    TLSA_HASH=$(openssl x509 -in "$CERT_PATH" -noout -pubkey 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}')
    if [ -n "$TLSA_HASH" ] && [ "$TLSA_HASH" != "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" ]; then
        echo ""
        echo "📋 DANE/TLSA Record:"
        echo "   Add this DNS record to enable DANE:"
        echo ""
        echo "   Type:  TLSA"
        # The host is the MX, not the webmail name: DANE is checked by sending
        # servers connecting to port 25.
        echo "   Host:  _25._tcp.${SMTP_HOSTNAME}"
        echo "   Value: 3 1 1 ${TLSA_HASH}"
        echo ""
        echo "   This hash is based on your certificate's public key."
        echo "   It stays the same across renewals (--reuse-key is enabled)."
        echo "   You only need to update this DNS record after a full reinstallation."
    fi
fi
