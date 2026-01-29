#!/bin/bash

# UNA.Email Installer
# One-click installation for self-hosted email

set -e

echo ""
echo "=========================================="
echo "       UNA.Email Installation"
echo "=========================================="
echo ""

# ============================================
# Step 1: Check Prerequisites
# ============================================
echo "Step 1: Checking Prerequisites"
echo "------------------------------"

if ! command -v docker &> /dev/null; then
    echo "❌ Docker is not installed."
    echo ""
    echo "   Install Docker first:"
    echo "   - CentOS/AlmaLinux: sudo dnf install -y docker && sudo systemctl enable --now docker"
    echo "   - Ubuntu/Debian:    sudo apt install -y docker.io && sudo systemctl enable --now docker"
    exit 1
fi

if ! docker compose version &> /dev/null; then
    echo "❌ Docker Compose is not available."
    echo ""
    echo "   Install Docker Compose:"
    echo "   - CentOS/AlmaLinux: sudo dnf install -y docker-compose-plugin"
    echo "   - Ubuntu/Debian:    sudo apt install -y docker-compose-plugin"
    exit 1
fi

if ! docker ps &> /dev/null; then
    echo "❌ Cannot connect to Docker daemon."
    echo ""
    echo "   Try:"
    echo "   sudo systemctl start docker"
    echo "   sudo usermod -aG docker $USER && newgrp docker"
    exit 1
fi

echo "✅ Docker: $(docker --version | cut -d' ' -f3 | tr -d ',')"
echo "✅ Docker Compose: $(docker compose version --short)"

# Configure firewall if present
if command -v firewall-cmd &> /dev/null && systemctl is-active --quiet firewalld; then
    echo "🔥 Configuring firewall (firewalld)..."
    firewall-cmd --add-port={22,25,80,443}/tcp --permanent > /dev/null 2>&1 || true
    firewall-cmd --reload > /dev/null 2>&1 || true
    echo "✅ Firewall ports opened (22, 25, 80, 443)"
elif command -v ufw &> /dev/null && ufw status | grep -q "Status: active"; then
    echo "🔥 Configuring firewall (ufw)..."
    ufw allow 22/tcp > /dev/null 2>&1 || true
    ufw allow 25/tcp > /dev/null 2>&1 || true
    ufw allow 80/tcp > /dev/null 2>&1 || true
    ufw allow 443/tcp > /dev/null 2>&1 || true
    echo "✅ Firewall ports opened (22, 25, 80, 443)"
else
    echo "ℹ️  No active firewall detected (or not running as root)"
fi
echo ""

# ============================================
# Step 2: Domain Configuration
# ============================================
echo "Step 2: Domain Configuration"
echo "----------------------------"

# Validate domain format
validate_domain() {
    local domain=$1
    if [[ ! $domain =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$ ]]; then
        return 1
    fi
    return 0
}

read -p "Enter your domain (e.g., example.com): " DOMAIN

if ! validate_domain "$DOMAIN"; then
    echo "❌ Invalid domain format"
    exit 1
fi

echo "✅ Domain: $DOMAIN"
echo ""

# ============================================
# Step 3: Email for SSL Certificate
# ============================================
echo "Step 3: SSL Certificate Email"
echo "-----------------------------"

read -p "Enter your email (for Let's Encrypt notifications): " LETSENCRYPT_EMAIL

echo "✅ Email: $LETSENCRYPT_EMAIL"
echo ""

# ============================================
# Step 4: Database Password
# ============================================
echo "Step 4: Database Password"
echo "-------------------------"

# Generate a random password
GENERATED_PASSWORD=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)

echo "Generated password: $GENERATED_PASSWORD"
echo ""
read -p "Press Enter to accept, or type your own password: " CUSTOM_PASSWORD

if [ -n "$CUSTOM_PASSWORD" ]; then
    DB_PASSWORD="$CUSTOM_PASSWORD"
    echo "✅ Using your custom password"
else
    DB_PASSWORD="$GENERATED_PASSWORD"
    echo "✅ Using generated password"
fi
echo ""

# ============================================
# Step 5: Create Configuration
# ============================================
echo "Step 5: Creating Configuration"
echo "------------------------------"

# Get server IP
SERVER_IP=$(curl -s ifconfig.me 2>/dev/null || curl -s icanhazip.com 2>/dev/null || echo "YOUR_SERVER_IP")

# Create .env file
cat > .env << EOF
# UNA.Email Configuration
# Generated: $(date)

DOMAIN=$DOMAIN
LETSENCRYPT_EMAIL=$LETSENCRYPT_EMAIL
DB_PASSWORD=$DB_PASSWORD
NODE_ENV=production
IMAGE_TAG=latest
EOF

echo "✅ Created .env file"

# Set permissions
chmod +x renew-ssl.sh 2>/dev/null || true
chmod +x nginx/entrypoint.sh 2>/dev/null || true

echo "✅ Set file permissions"
echo ""

# ============================================
# Step 6: Start Services
# ============================================
echo "Step 6: Starting Services"
echo "-------------------------"

echo "🚀 Pulling Docker images..."
docker compose pull

echo "🚀 Starting containers..."
docker compose up -d

echo "⏳ Waiting for services to initialize..."
sleep 20

echo "📋 Service status:"
docker compose ps --format "table {{.Name}}\t{{.Status}}"
echo ""

# ============================================
# Step 7: Initialize Database
# ============================================
echo "Step 7: Database Setup"
echo "----------------------"

echo "🗄️  Creating database schema..."
docker compose exec -T web npx prisma db push --accept-data-loss

echo "✅ Database ready"
echo ""

# ============================================
# Step 8: SSL Certificate
# ============================================
echo "Step 8: SSL Certificate"
echo "-----------------------"

if docker compose run --rm certbot certificates 2>/dev/null | grep -q "mail.$DOMAIN"; then
    echo "✅ SSL certificate already exists"
else
    echo "🔒 Requesting SSL certificate for mail.$DOMAIN..."
    if docker compose run --rm certbot certonly --webroot --webroot-path=/var/www/certbot --email "$LETSENCRYPT_EMAIL" --agree-tos --no-eff-email -d "mail.$DOMAIN"; then
        echo "✅ SSL certificate obtained"
    else
        echo "⚠️  SSL certificate request failed (may be rate limited)"
        echo "   You can retry later with: ./renew-ssl.sh --force"
    fi
fi

# Sync certs to Postfix and restart
docker compose exec -T postfix sh -c 'mkdir -p /etc/postfix/tls; if [ -f "/etc/letsencrypt/live/mail.'"$DOMAIN"'/fullchain.pem" ]; then cp -f "/etc/letsencrypt/live/mail.'"$DOMAIN"'/fullchain.pem" /etc/postfix/tls/fullchain.pem && cp -f "/etc/letsencrypt/live/mail.'"$DOMAIN"'/privkey.pem" /etc/postfix/tls/privkey.pem && chmod 640 /etc/postfix/tls/privkey.pem; fi; postfix reload 2>/dev/null' || true
docker compose restart nginx postfix >/dev/null 2>&1
echo ""

# ============================================
# Step 9: Generate Setup Instructions
# ============================================
echo "Step 9: Generating Setup Guide"
echo "------------------------------"

cat > YOUR_SETUP.md << EOF
# UNA Email Setup for $DOMAIN

Generated: $(date)
Server IP: $SERVER_IP

---

## DNS Records to Add

Add these records at your domain registrar (Cloudflare, Namecheap, GoDaddy, etc.)

### 1. MX Record (Required)
Tells email servers where to deliver mail for your domain.

| Type | Host | Value | Priority |
|------|------|-------|----------|
| MX | @ | mail.$DOMAIN | 10 |

### 2. A Record (Required)
Points your mail server hostname to your server.

| Type | Host | Value |
|------|------|-------|
| A | mail | $SERVER_IP |

### 3. SPF Record (Required)
Tells receivers which servers can send email for your domain.

| Type | Host | Value |
|------|------|-------|
| TXT | @ | v=spf1 a:mail.$DOMAIN ip4:$SERVER_IP mx ~all |

### 4. DKIM Record (Required)
Cryptographic signature for email authentication.

| Type | Host | Value |
|------|------|-------|
| TXT | una._domainkey | (see below) |

**To get your DKIM value, run this command on your server:**
\`\`\`bash
docker compose exec rspamd cat /var/lib/rspamd/dkim/una.$DOMAIN.txt 2>/dev/null || echo "DKIM key not yet generated - send a test email first"
\`\`\`

### 5. DMARC Record (Recommended)
Policy for handling authentication failures.

| Type | Host | Value |
|------|------|-------|
| TXT | _dmarc | v=DMARC1; p=none; rua=mailto:$LETSENCRYPT_EMAIL |

### 6. Reverse DNS / PTR Record (Required)
Set this in your VPS provider's control panel (Vultr, DigitalOcean, etc.), NOT your domain registrar.

| Server IP | PTR Value |
|-----------|-----------|
| $SERVER_IP | mail.$DOMAIN |

---

## Verification Commands

After adding DNS records (allow 5-30 minutes for propagation):

\`\`\`bash
# Check MX record
dig MX $DOMAIN +short

# Check A record
dig A mail.$DOMAIN +short

# Check SPF record
dig TXT $DOMAIN +short | grep spf

# Check DKIM record
dig TXT una._domainkey.$DOMAIN +short
\`\`\`

---

## Your Installation

- **Web Interface:** https://mail.$DOMAIN
- **SMTP Server:** mail.$DOMAIN (port 25)

---

## Maintenance

**Update UNA Email:**
\`\`\`bash
./update.sh
\`\`\`

**Renew SSL (runs automatically via cron, but can be manual):**
\`\`\`bash
./renew-ssl.sh
\`\`\`

**View logs:**
\`\`\`bash
docker compose logs -f postfix    # Mail server
docker compose logs -f web        # Web interface
docker compose logs -f rspamd     # Spam filter
\`\`\`

---

## Need Help?

- Documentation: https://una.email/docs
- Support: support@una.email

EOF

echo "✅ Created YOUR_SETUP.md"
echo ""

# ============================================
# Installation Complete
# ============================================
echo ""
echo "=========================================="
echo "       Installation Complete!"
echo "=========================================="
echo ""
echo "📄 IMPORTANT: Open YOUR_SETUP.md for DNS configuration"
echo "   This file contains all the DNS records you need to add."
echo ""
echo "🌐 Web Interface: https://mail.$DOMAIN"
echo ""
echo "📋 Quick Commands:"
echo "   ./update.sh      - Update to latest version"
echo "   ./renew-ssl.sh   - Renew SSL certificate"
echo ""
echo "🔧 Set up automatic SSL renewal:"
echo "   sudo crontab -e"
echo "   Add: 30 2 * * * $(pwd)/renew-ssl.sh > /dev/null 2>&1"
echo ""
