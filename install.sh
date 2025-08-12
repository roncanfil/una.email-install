#!/bin/bash

# UNA.Email Configuration Generator

set -e

echo "=== UNA.Email Installation ==="
echo "This script will install and configure una.email for your domain"
echo ""

# Check Docker installation
echo "=== Checking Prerequisites ==="
echo "🐳 Checking Docker installation..."

if ! command -v docker &> /dev/null; then
    echo "❌ Docker is not installed. Please install Docker first:"
    echo "   For CentOS/AlmaLinux/RHEL:"
    echo "   sudo dnf install -y docker"
    echo "   sudo systemctl start docker"
    echo "   sudo systemctl enable docker"
    echo ""
    echo "   For Ubuntu/Debian:"
    echo "   sudo apt update && sudo apt install -y docker.io"
    echo "   sudo systemctl start docker"
    echo "   sudo systemctl enable docker"
    exit 1
fi

if ! docker compose version &> /dev/null; then
    echo "❌ Docker Compose is not installed or not working. Please install Docker Compose:"
    echo "   sudo dnf install -y docker-compose-plugin  # CentOS/AlmaLinux/RHEL"
    echo "   sudo apt install -y docker-compose-plugin  # Ubuntu/Debian"
    exit 1
fi

if ! docker ps &> /dev/null; then
    echo "❌ Docker daemon is not running or permission denied. Please:"
    echo "   sudo systemctl start docker"
    echo "   sudo usermod -aG docker $USER"
    echo "   Then logout and login again, or run: newgrp docker"
    exit 1
fi

echo "✅ Docker: $(docker --version)"
echo "✅ Docker Compose: $(docker compose version --short)"
echo ""

# Function to validate domain format
validate_domain() {
    local domain=$1
    if [[ ! $domain =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
        echo "❌ Invalid domain format: $domain"
        return 1
    fi
    return 0
}

# Get domain from user
read -p "Enter your domain (e.g., example.com): " DOMAIN

# Validate domain
if ! validate_domain "$DOMAIN"; then
    echo "Please enter a valid domain name"
    exit 1
fi

# Get email from user for Let's Encrypt
read -p "Enter your email address (for Let's Encrypt SSL certificate): " LETSENCRYPT_EMAIL

echo ""
echo "✅ Domain validated: $DOMAIN"
echo ""

# Create .env file if it doesn't exist
if [ ! -f .env ]; then
    echo "Creating .env file..."
    cat > .env << EOF
# UNA.Email Configuration
DOMAIN=$DOMAIN
LETSENCRYPT_EMAIL=$LETSENCRYPT_EMAIL
DB_PASSWORD=una_email_password
NODE_ENV=production
IMAGE_TAG=latest
EOF
    echo "✅ Created .env file"
else
    echo "📝 Updating existing .env file..."
    # Update DOMAIN in existing .env file
    if grep -q "^DOMAIN=" .env; then
        # Use sed with different options for macOS compatibility
        if [[ "$OSTYPE" == "darwin"* ]]; then
            sed -i '' "s/^DOMAIN=.*/DOMAIN=$DOMAIN/" .env
        else
            sed -i "s/^DOMAIN=.*/DOMAIN=$DOMAIN/" .env
        fi
    else
        echo "DOMAIN=$DOMAIN" >> .env
    fi
    # Update LETSENCRYPT_EMAIL in existing .env file
    if grep -q "^LETSENCRYPT_EMAIL=" .env; then
        if [[ "$OSTYPE" == "darwin"* ]]; then
            sed -i '' "s/^LETSENCRYPT_EMAIL=.*/LETSENCRYPT_EMAIL=$LETSENCRYPT_EMAIL/" .env
        else
            sed -i "s/^LETSENCRYPT_EMAIL=.*/LETSENCRYPT_EMAIL=$LETSENCRYPT_EMAIL/" .env
        fi
    else
        echo "LETSENCRYPT_EMAIL=$LETSENCRYPT_EMAIL" >> .env
    fi
    echo "✅ Updated .env file"
fi

echo ""

# Verify Postfix configuration templates exist
echo "📧 Verifying Postfix configuration templates..."
if [ ! -f mail/main.cf.template ] || [ ! -f mail/transport.template ]; then
    echo "❌ Error: Template files not found. Please ensure mail/main.cf.template and mail/transport.template exist."
    exit 1
fi
echo "✅ Found Postfix configuration templates"

# Set permissions for entrypoint script
if [ -f mail/entrypoint.sh ]; then
    chmod +x mail/entrypoint.sh
    echo "✅ Set permissions for mail/entrypoint.sh"
fi

# Set permissions for SSL renewal script
if [ -f renew-ssl.sh ]; then
    chmod +x renew-ssl.sh
    echo "✅ Set permissions for renew-ssl.sh"
fi

# Ensure delivery script is executable
if [ -f mail/deliver-to-maildrop ]; then
    chmod +x mail/deliver-to-maildrop
    echo "✅ Set permissions for mail/deliver-to-maildrop"
fi

# On SELinux systems (e.g., AlmaLinux/RHEL), add :Z relabel to bind mounts so scripts are executable in container
echo ""
echo "=== Host Compatibility (SELinux) ==="
if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce)" != "Disabled" ]; then
    echo "🔐 SELinux detected ($(getenforce)). Applying :Z to Postfix bind mounts in docker-compose.yml"
    # Apply :Z only if not already present
    sed -i -E "s#(\./mail/main\.cf\.template:/etc/postfix/main\.cf\.template)(:Z)?$#\1:Z#" docker-compose.yml || true
    sed -i -E "s#(\./mail/master\.cf:/etc/postfix/master\.cf)(:Z)?$#\1:Z#" docker-compose.yml || true
    sed -i -E "s#(\./mail/transport\.template:/etc/postfix/transport\.template)(:Z)?$#\1:Z#" docker-compose.yml || true
    sed -i -E "s#(\./mail/entrypoint\.sh:/app/entrypoint\.sh)(:Z)?$#\1:Z#" docker-compose.yml || true
    sed -i -E "s#(\./mail/deliver-to-maildrop:/app/deliver-to-maildrop)(:Z)?$#\1:Z#" docker-compose.yml || true
    echo "✅ Updated bind mounts with :Z labels"
else
    echo "ℹ️  SELinux not detected or disabled; no relabeling needed"
fi

echo ""
echo "=== Starting Services ==="
echo ""

# Start all services
echo "🚀 Starting Docker services..."
docker compose up -d

# Wait for services to initialize
echo "⏳ Waiting for services to initialize..."
sleep 15

# Check if services are running
echo "📋 Checking service status..."
docker compose ps

# Quick Postfix sanity: render transport from template (container entrypoint also does this)
echo ""
echo "=== Postfix Sanity Check ==="
docker compose exec -T postfix sh -lc "postmap /etc/postfix/transport 2>/dev/null || true; postmap /etc/postfix/virtual 2>/dev/null || true; postconf -n | egrep '^(transport_maps|myhostname|mydomain|mydestination|smtpd_use_tls|smtpd_tls_cert_file|smtpd_tls_key_file)$' | cat; echo '--- transport ---'; [ -f /etc/postfix/transport ] && sed -n '1,50p' /etc/postfix/transport | cat || echo missing; echo '--- handler ---'; egrep '^una-email-handler' -A1 /etc/postfix/master.cf | cat" || true

# Initialize database
echo ""
echo "=== Initializing Database ==="
echo "🗄️  Running database migrations..."
docker compose exec -T web npx prisma migrate deploy

# Verify database tables
echo "✅ Verifying database tables..."
docker compose exec -T postgres psql -U una_email -d una_email -c "\dt" | grep -q "emails" && echo "✅ Database tables created successfully" || echo "❌ Database initialization failed"

# Create a default alias
echo "📧 Creating default alias: hello@$DOMAIN"
docker compose exec -T postgres psql -U una_email -d una_email -c "INSERT INTO aliases (alias, created_at) VALUES ('hello', NOW()) ON CONFLICT DO NOTHING;"

echo ""
echo "=== SSL Certificate Setup ==="
echo "🔒 Obtaining SSL certificate..."

# Check if certificate already exists
if docker compose run --rm certbot certificates | grep -q "mail.$DOMAIN"; then
    echo "ℹ️  Certificate already exists for mail.$DOMAIN, skipping certificate request..."
    echo "✅ Using existing SSL certificate"
else
    echo "🆕 Obtaining new certificate for mail.$DOMAIN..."
    if ! docker compose run --rm certbot certonly --webroot --webroot-path=/var/www/certbot --email $LETSENCRYPT_EMAIL --agree-tos --no-eff-email -d mail.$DOMAIN; then
        echo "⚠️  SSL certificate request failed (possibly rate limited)"
        echo "ℹ️  Your email server will work with HTTP only"
        echo "ℹ️  You can manually request SSL later: ./renew-ssl.sh"
        echo "ℹ️  Or wait for rate limits to reset and run: docker compose run --rm certbot certonly --webroot --webroot-path=/var/www/certbot --email $LETSENCRYPT_EMAIL --agree-tos --no-eff-email -d mail.$DOMAIN"
    fi
fi

echo "🔄 Syncing certs into Postfix chroot and restarting services..."
docker compose exec -T postfix sh -lc 'mkdir -p /etc/postfix/tls; if [ -f "/etc/letsencrypt/live/mail.'"$DOMAIN"'/fullchain.pem" ] && [ -f "/etc/letsencrypt/live/mail.'"$DOMAIN"'/privkey.pem" ]; then cp -f "/etc/letsencrypt/live/mail.'"$DOMAIN"'/fullchain.pem" /etc/postfix/tls/fullchain.pem && cp -f "/etc/letsencrypt/live/mail.'"$DOMAIN"'/privkey.pem" /etc/postfix/tls/privkey.pem && chown root:postfix /etc/postfix/tls/privkey.pem && chmod 640 /etc/postfix/tls/privkey.pem; fi; postfix reload' || true
docker compose restart nginx postfix

echo ""
echo "=== Installation Complete ==="
echo ""
echo "✅ UNA.Email is now fully installed and configured for domain: $DOMAIN"
echo ""
echo "🌐 Web Interface: https://mail.$DOMAIN"
echo "📧 Test Email: Send to hello@$DOMAIN (e.g., from ProtonMail)"
echo ""
echo "📋 Next Steps:"
echo "1. Set up MX record in your DNS: mail.$DOMAIN (priority 10)"
echo "2. Set up SSL auto-renewal: sudo crontab -e"
echo "   Add: 30 2 * * * $(pwd)/renew-ssl.sh > /dev/null 2>&1"
echo "3. Verify pipeline: docker compose exec postfix postqueue -p | cat; docker compose exec postgres psql -U una_email -d una_email -c 'SELECT id, subject, from_email, created_at FROM emails ORDER BY created_at DESC LIMIT 10;'"
echo ""
echo "🎉 Your email server is ready!" 