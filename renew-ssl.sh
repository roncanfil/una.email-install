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

# Function to sync certificate to Postfix
sync_to_postfix() {
    echo "Syncing certificate to Postfix..."
    docker compose exec -T postfix sh -lc 'mkdir -p /etc/postfix/tls; if [ -f "/etc/letsencrypt/live/mail.'"$DOMAIN"'/fullchain.pem" ] && [ -f "/etc/letsencrypt/live/mail.'"$DOMAIN"'/privkey.pem" ]; then cp -f "/etc/letsencrypt/live/mail.'"$DOMAIN"'/fullchain.pem" /etc/postfix/tls/fullchain.pem && cp -f "/etc/letsencrypt/live/mail.'"$DOMAIN"'/privkey.pem" /etc/postfix/tls/privkey.pem && chown root:postfix /etc/postfix/tls/privkey.pem && chmod 640 /etc/postfix/tls/privkey.pem; fi; postfix reload' || true
}

# Function to restart Nginx
restart_nginx() {
    echo "Restarting Nginx to apply new certificate..."
    docker compose restart nginx
}

# Check if certificate exists and is expired
CERT_EXPIRED=false
if docker compose run --rm certbot certificates 2>/dev/null | grep -q "mail.$DOMAIN"; then
    # Certificate exists, check expiration
    EXPIRY_DATE=$(docker compose run --rm certbot certificates 2>/dev/null | grep -A 5 "mail.$DOMAIN" | grep "Expiry Date" | awk '{print $3, $4, $5, $6}' || echo "")
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
    if [ -z "${LETSENCRYPT_EMAIL:-}" ]; then
        echo "❌ Error: LETSENCRYPT_EMAIL not set in .env file (required for force renewal)"
        exit 1
    fi
    
    if [ "$CERT_EXPIRED" = true ]; then
        echo "⚠️  Certificate is expired. Using force renewal method..."
    else
        echo "🔄 Force renewal requested..."
    fi
    echo ""
    
    # Step 1: Delete old certificate
    echo "📋 Step 1: Removing old certificate..."
    docker compose run --rm certbot delete --cert-name mail.$DOMAIN --non-interactive || true
    
    echo ""
    echo "📋 Step 2: Obtaining new certificate..."
    if ! docker compose run --rm certbot certonly --webroot --webroot-path=/var/www/certbot --email $LETSENCRYPT_EMAIL --agree-tos --no-eff-email -d mail.$DOMAIN; then
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
    echo "🌐 Your website should now be accessible at https://mail.$DOMAIN"
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
