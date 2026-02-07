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

# Default MAIL_SUBDOMAIN to 'mail' if not set
MAIL_SUBDOMAIN="${MAIL_SUBDOMAIN:-mail}"
FULL_HOSTNAME="${MAIL_SUBDOMAIN}.${DOMAIN}"

# Function to sync certificate to Postfix
sync_to_postfix() {
    echo "Syncing certificate to Postfix..."
    docker compose exec -T postfix sh -lc 'mkdir -p /etc/postfix/tls; if [ -f "/etc/letsencrypt/live/'"$FULL_HOSTNAME"'/fullchain.pem" ] && [ -f "/etc/letsencrypt/live/'"$FULL_HOSTNAME"'/privkey.pem" ]; then cp -f "/etc/letsencrypt/live/'"$FULL_HOSTNAME"'/fullchain.pem" /etc/postfix/tls/fullchain.pem && cp -f "/etc/letsencrypt/live/'"$FULL_HOSTNAME"'/privkey.pem" /etc/postfix/tls/privkey.pem && chown root:postfix /etc/postfix/tls/privkey.pem && chmod 640 /etc/postfix/tls/privkey.pem; fi; postfix reload' || true
}

# Function to restart Nginx
restart_nginx() {
    echo "Restarting Nginx to apply new certificate..."
    docker compose restart nginx
}

# Check if certificate exists
CERT_EXISTS=false
if docker compose run --rm certbot certificates 2>/dev/null | grep -q "$FULL_HOSTNAME"; then
    CERT_EXISTS=true
fi

if [ "$CERT_EXISTS" = false ]; then
    # No certificate exists — obtain a new one
    echo "📋 No certificate found for $FULL_HOSTNAME. Obtaining a new one..."
    echo ""

    # Clean up any leftover directories
    rm -rf ./letsencrypt/etc/live/$FULL_HOSTNAME 2>/dev/null || true
    rm -rf ./letsencrypt/etc/archive/$FULL_HOSTNAME 2>/dev/null || true
    rm -f ./letsencrypt/etc/renewal/$FULL_HOSTNAME.conf 2>/dev/null || true

    if ! docker compose run --rm certbot certonly --webroot --webroot-path=/var/www/certbot --register-unsafely-without-email --agree-tos -d $FULL_HOSTNAME; then
        echo "❌ SSL certificate request failed"
        echo "ℹ️  Common issues:"
        echo "   - DNS not pointing to this server"
        echo "   - Port 80 not accessible"
        echo "   - Rate limiting (wait a few hours)"
        exit 1
    fi

    sync_to_postfix
    restart_nginx

    echo ""
    echo "✅ SSL certificate obtained!"
    echo "🌐 Your website should now be accessible at https://$FULL_HOSTNAME"
elif [ "$CRON_MODE" = true ]; then
    # Cron mode — quiet renewal
    if docker compose run --rm certbot renew --quiet 2>/dev/null; then
        sync_to_postfix
        restart_nginx
    fi
else
    # Manual renewal
    echo "🔄 Renewing SSL certificate for $FULL_HOSTNAME..."
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
CERT_PATH="./letsencrypt/etc/live/${FULL_HOSTNAME}/cert.pem"
if [ -f "$CERT_PATH" ]; then
    TLSA_HASH=$(openssl x509 -in "$CERT_PATH" -outform DER 2>/dev/null | sha256sum | awk '{print $1}')
    if [ -n "$TLSA_HASH" ] && [ "$TLSA_HASH" != "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" ]; then
        echo ""
        echo "📋 DANE/TLSA Record:"
        echo "   Add this DNS record to enable DANE:"
        echo ""
        echo "   Type:  TLSA"
        echo "   Host:  _25._tcp.mail.${DOMAIN}"
        echo "   Value: 3 1 1 ${TLSA_HASH}"
        echo ""
        echo "   Note: Update this record each time the SSL certificate renews."
    fi
fi
