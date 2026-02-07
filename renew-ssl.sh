#!/bin/bash

# Unified SSL certificate renewal script for Una.Email
# Automatically handles both normal renewal and expired certificate renewal

set -e

cd "$(dirname "$0")"

# Check for --force flag
FORCE_RENEW=false
if [[ "$1" == "--force" ]] || [[ "$1" == "-f" ]]; then
    FORCE_RENEW=true
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

# Check if certificate exists and is expired
CERT_EXPIRED=false
if docker compose run --rm certbot certificates 2>/dev/null | grep -q "$FULL_HOSTNAME"; then
    # Certificate exists, check expiration
    EXPIRY_DATE=$(docker compose run --rm certbot certificates 2>/dev/null | grep -A 5 "$FULL_HOSTNAME" | grep "Expiry Date" | awk '{print $3, $4, $5, $6}' || echo "")
    if [ -n "$EXPIRY_DATE" ]; then
        # Convert expiry date to epoch and compare with current date
        EXPIRY_EPOCH=$(date -d "$EXPIRY_DATE" +%s 2>/dev/null || date -j -f "%b %d %H:%M:%S %Y %Z" "$EXPIRY_DATE" +%s 2>/dev/null || echo "0")
        CURRENT_EPOCH=$(date +%s)
        if [ "$EXPIRY_EPOCH" -lt "$CURRENT_EPOCH" ]; then
            CERT_EXPIRED=true
        fi
    fi
else
    # Certificate doesn't exist
    CERT_EXPIRED=true
fi

# Determine renewal method
if [ "$FORCE_RENEW" = true ] || [ "$CERT_EXPIRED" = true ]; then
    # Force renewal path (for expired certificates or manual override)
    if [ "$CERT_EXPIRED" = true ]; then
        echo "⚠️  Certificate is expired. Using force renewal method..."
    else
        echo "🔄 Force renewal requested..."
    fi
    echo ""

    # Step 1: Delete old certificate and clean up any leftover directories
    echo "📋 Step 1: Removing old certificate..."
    docker compose run --rm certbot delete --cert-name $FULL_HOSTNAME --non-interactive 2>/dev/null || true

    # Also remove any leftover directories that might cause "live directory exists" error
    rm -rf ./letsencrypt/etc/live/$FULL_HOSTNAME 2>/dev/null || true
    rm -rf ./letsencrypt/etc/archive/$FULL_HOSTNAME 2>/dev/null || true
    rm -f ./letsencrypt/etc/renewal/$FULL_HOSTNAME.conf 2>/dev/null || true

    echo ""
    echo "📋 Step 2: Obtaining new certificate..."
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
    echo "✅ SSL certificate force renewal complete!"
    echo "🌐 Your website should now be accessible at https://$FULL_HOSTNAME"
else
    # Normal renewal path (for cron jobs)
    echo "Attempting to renew SSL certificate (normal renewal)..."
    if docker compose run --rm certbot renew; then
        echo "✅ Certificate renewal check completed"

        # Only sync and restart if certbot actually renewed something
        # certbot renew returns 0 even if nothing was renewed, so we check the exit code
        sync_to_postfix
        restart_nginx

        echo "✅ SSL renewal process complete."
    else
        echo "⚠️  Certificate renewal failed"
        echo "ℹ️  If your certificate is expired, run: ./renew-ssl.sh --force"
        exit 1
    fi
fi

# Generate DANE/TLSA record (if certificate exists)
CERT_PATH="./letsencrypt/etc/live/${FULL_HOSTNAME}/cert.pem"
if [ -f "$CERT_PATH" ]; then
    TLSA_HASH=$(openssl x509 -in "$CERT_PATH" -outform DER 2>/dev/null | sha256sum | awk '{print $1}')
    if [ -n "$TLSA_HASH" ] && [ "$TLSA_HASH" != "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" ]; then
        echo ""
        echo "📋 DANE/TLSA Record (optional, for enhanced security):"
        echo "   Add this DNS record to enable DANE:"
        echo ""
        echo "   Type:  TLSA"
        echo "   Host:  _25._tcp.mail.${DOMAIN}"
        echo "   Value: 3 1 1 ${TLSA_HASH}"
        echo ""
        echo "   Note: Update this record each time the SSL certificate renews."
    fi
fi
