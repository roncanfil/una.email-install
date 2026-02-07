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

read -p "Subdomain for web access [webmail]: " MAIL_SUBDOMAIN
MAIL_SUBDOMAIN="${MAIL_SUBDOMAIN:-webmail}"
echo "✅ Web UI will be at: https://$MAIL_SUBDOMAIN.$DOMAIN"
echo ""

# ============================================
# Step 3: Database Password
# ============================================
echo "Step 3: Database Password"
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
# Step 4: Create Configuration
# ============================================
echo "Step 4: Creating Configuration"
echo "------------------------------"

# Get server IP (force IPv4)
SERVER_IP=$(curl -4 -s ifconfig.me 2>/dev/null || curl -4 -s icanhazip.com 2>/dev/null || curl -s api.ipify.org 2>/dev/null || echo "YOUR_SERVER_IP")

# Create .env file
cat > .env << EOF
# UNA.Email Configuration
# Generated: $(date)

DOMAIN=$DOMAIN
MAIL_SUBDOMAIN=$MAIL_SUBDOMAIN
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
# Step 5: Start Services
# ============================================
echo "Step 5: Starting Services"
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
# Step 6: Initialize Database
# ============================================
echo "Step 6: Database Setup"
echo "----------------------"

echo "🗄️  Creating database schema..."
docker compose exec -T web npx prisma db push --accept-data-loss > /dev/null 2>&1
echo "✅ Database ready"
echo ""

# ============================================
# Step 7: Generate DKIM Key
# ============================================
echo "Step 7: Generating DKIM Key"
echo "---------------------------"

echo "🔑 Creating DKIM signing key..."

# Create the DKIM directory if it doesn't exist
docker compose exec -T rspamd mkdir -p /var/lib/rspamd/dkim

# Generate the DKIM key (rspamadm creates the key in the correct format for rspamd)
docker compose exec -T rspamd rspamadm dkim_keygen -s una -d $DOMAIN -k /var/lib/rspamd/dkim/una.$DOMAIN.key > /dev/null 2>&1

# Set proper permissions on the private key
docker compose exec -T rspamd chmod 640 /var/lib/rspamd/dkim/una.$DOMAIN.key 2>/dev/null || true
docker compose exec -T rspamd chown _rspamd:_rspamd /var/lib/rspamd/dkim/una.$DOMAIN.key 2>/dev/null || true

# Extract the public key directly from the private key file using openssl
# This is more reliable than parsing rspamadm output
DKIM_PUBKEY=$(docker compose exec -T rspamd openssl rsa -in /var/lib/rspamd/dkim/una.$DOMAIN.key -pubout 2>/dev/null | grep -v "^-" | tr -d '\n')

if [ -n "$DKIM_PUBKEY" ]; then
    DKIM_RECORD="v=DKIM1; k=rsa; p=$DKIM_PUBKEY"
    echo "✅ DKIM key generated"
else
    DKIM_RECORD="v=DKIM1; k=rsa; p=<run: docker compose exec rspamd openssl rsa -in /var/lib/rspamd/dkim/una.$DOMAIN.key -pubout 2>/dev/null | grep -v '^-' | tr -d '\\n'>"
    echo "⚠️  DKIM key generated but could not extract public key automatically"
fi

# Create symlink for mail. subdomain DKIM (for bounce messages from mail.$DOMAIN)
docker compose exec -T rspamd ln -sf /var/lib/rspamd/dkim/una.$DOMAIN.key /var/lib/rspamd/dkim/una.mail.$DOMAIN.key 2>/dev/null || true
echo ""

# ============================================
# Step 8: Generate Setup Instructions
# ============================================
echo "Step 8: Generating Setup Guide"
echo "------------------------------"

cat > YOUR_SETUP.md << EOF
# UNA Email Setup for $DOMAIN

Generated: $(date)
Server IP: $SERVER_IP

---

## Step 1: Add DNS Records

Add these records at your domain registrar (Cloudflare, Namecheap, GoDaddy, etc.)

### 1. MX Record
Tells email servers where to deliver mail for your domain.

| Type | Host | Value | Priority |
|------|------|-------|----------|
| MX | @ | mail.$DOMAIN | 10 |

### 2. A Records
Point your hostnames to your server.

| Type | Host | Value | Purpose |
|------|------|-------|---------|
| A | mail | $SERVER_IP | Mail server (SMTP) |
| A | $MAIL_SUBDOMAIN | $SERVER_IP | Web interface |

### 3. SPF Record
Tells receivers which servers can send email for your domain.

| Type | Host | Value |
|------|------|-------|
| TXT | @ | v=spf1 a:mail.$DOMAIN ip4:$SERVER_IP mx ~all |

### 4. DKIM Records
Cryptographic signature for email authentication. You need TWO DKIM records:

| Type | Host | Value |
|------|------|-------|
| TXT | una._domainkey | $DKIM_RECORD |
| TXT | una._domainkey.mail | $DKIM_RECORD |

**Note:** Both records use the same value. The second one is for bounce messages sent from mail.$DOMAIN.

### 5. DMARC Record
Policy for handling authentication failures.

| Type | Host | Value |
|------|------|-------|
| TXT | _dmarc | v=DMARC1; p=none; adkim=s; aspf=s; rua=mailto:postmaster@$DOMAIN; ruf=mailto:postmaster@$DOMAIN; fo=1; pct=100 |

### 6. Reverse DNS / PTR Record
Set this in your VPS provider's control panel (Vultr, DigitalOcean, etc.), NOT your domain registrar.

| Server IP | PTR Value |
|-----------|-----------|
| $SERVER_IP | mail.$DOMAIN |

---

## Step 2: Verify DNS Records

After adding DNS records, wait 5-30 minutes for propagation, then verify:

\`\`\`bash
# Check MX record
dig MX $DOMAIN +short
\`\`\`
**Expected output:**
\`\`\`
10 mail.$DOMAIN.
\`\`\`

\`\`\`bash
# Check A records
dig A mail.$DOMAIN +short
dig A $MAIL_SUBDOMAIN.$DOMAIN +short
\`\`\`
**Expected output (both should return):**
\`\`\`
$SERVER_IP
\`\`\`

\`\`\`bash
# Check SPF record
dig TXT $DOMAIN +short | grep spf
\`\`\`
**Expected output:**
\`\`\`
"v=spf1 a:mail.$DOMAIN ip4:$SERVER_IP mx ~all"
\`\`\`

\`\`\`bash
# Check DKIM record
dig TXT una._domainkey.$DOMAIN +short
\`\`\`
**Expected output:** Should return your DKIM public key starting with \`"v=DKIM1; k=rsa; p=MIG...\`

---

## Step 3: Get SSL Certificate

Once DNS is verified, obtain your SSL certificate:

\`\`\`bash
./renew-ssl.sh
\`\`\`

The script will automatically detect that no certificate exists and obtain a new one.

---

## Step 4: Add DANE/TLSA DNS Record

After obtaining your SSL certificate, the \`renew-ssl.sh\` script displays your TLSA hash.
You can also generate it manually:

\`\`\`bash
openssl x509 -in ./letsencrypt/etc/live/$MAIL_SUBDOMAIN.$DOMAIN/cert.pem -outform DER | sha256sum
\`\`\`

Add this DNS record:

| Type | Host | Value |
|------|------|-------|
| TLSA | _25._tcp.mail | 3 1 1 <hash-from-command-above> |

**Note:** The TLSA record must be updated each time the SSL certificate renews.
The \`renew-ssl.sh\` script will display the current hash after each renewal.

---

## Step 5: Access Your Email

Open your browser and go to:

**https://$MAIL_SUBDOMAIN.$DOMAIN**

You should see the UNA Email login page with a valid SSL certificate (green padlock).

---

## Step 6: Test Your Email Deliverability

Before sending important emails, verify everything is configured correctly:

1. Go to **https://mail-tester.com/**
2. You'll see a unique email address like \`test-abc123@srv1.mail-tester.com\`
3. Copy that address
4. From your UNA Email web interface, compose a new email:
   - **To:** paste the mail-tester.com address
   - **Subject:** Write a short sentence (e.g., "Testing my new email server")
   - **Body:** Write at least 2-3 sentences of normal text (avoid spammy words)
5. Send the email
6. Go back to mail-tester.com and click **"Then check your score"**
7. You should see a score out of 10

### What to look for:
- **10/10**: Perfect! Your server is fully configured
- **SPF**: Should show green — verifies your server is authorized to send
- **DKIM**: Should show green — verifies your email signature
- **DMARC**: Should show green — verifies your domain policy
- **Blacklists**: Should show green — your IP is not blacklisted
- **PTR Record**: Should show green — reverse DNS is configured

### If your score is below 8:
- Check which items are marked with red or yellow
- Most issues are DNS records that need to be added or corrected
- PTR record issues must be fixed at your VPS provider, not your domain registrar
- Wait 24 hours after DNS changes and test again

**Tip:** You get 3 free tests per day. Test once after initial setup,
then again after making any DNS changes.

---

## Your Installation Details

- **Web Interface:** https://$MAIL_SUBDOMAIN.$DOMAIN
- **SMTP Server:** mail.$DOMAIN (port 25)
- **Server IP:** $SERVER_IP

---

## Maintenance

**Update UNA Email:**
\`\`\`bash
./update.sh
\`\`\`

**Renew SSL manually:**
\`\`\`bash
./renew-ssl.sh
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
echo "     ✨ Installation Complete! ✨"
echo "=========================================="
echo ""
echo "📄 Your personalized setup guide has been created:"
echo ""
echo "   cat YOUR_SETUP.md"
echo ""
echo "   Follow the steps in the guide to finish setup."
echo "   It only takes a few minutes!"
echo ""
echo "🌐 Once complete, access your email at:"
echo "   https://$MAIL_SUBDOMAIN.$DOMAIN"
echo ""
