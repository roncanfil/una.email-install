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
# Step 3b: Outbound relay (optional)
# ============================================
#
# Two directions, one port number, and confusing them is the classic
# self-hosted mail failure. INBOUND 25 is required no matter what is answered
# here -- the MX points at this box. OUTBOUND 25 is what most VPS providers
# block, and what a relay replaces.
#
# Declining is a first-class answer: the keys are written commented out, so the
# operator who later discovers their mail is not arriving finds them already in
# .env with the values named, rather than having to go and look up what they
# are called.
echo "Step 3b: Outbound Mail"
echo "----------------------"
echo ""
echo "By default UNA delivers mail straight to each recipient's mail server on"
echo "port 25. That needs OUTBOUND port 25 open, which many providers block, and"
echo "an IP with a clean reputation."
echo ""
echo "You can instead hand outbound mail to Amazon SES over port 587. This does"
echo "not change receiving: inbound port 25 is still required either way."
echo ""
read -p "Send outbound mail through Amazon SES? [y/N]: " USE_SES
echo ""

SES_ENABLED=false
if [ "$USE_SES" = "y" ] || [ "$USE_SES" = "Y" ]; then
    echo "SES issues its own SMTP credentials. These are NOT your AWS access key"
    echo "and secret -- create them in the SES console under"
    echo "Account dashboard -> Create SMTP credentials."
    echo ""
    read -p "SES region [us-east-1]: " SES_REGION
    SES_REGION=${SES_REGION:-us-east-1}
    read -p "SES SMTP username: " SES_USERNAME
    # -s so the password is not left on screen or in a scrollback buffer. It is
    # still written to .env, which is chmod 600 below.
    read -s -p "SES SMTP password: " SES_PASSWORD
    echo ""
    echo ""

    if [ -z "$SES_USERNAME" ] || [ -z "$SES_PASSWORD" ]; then
        # Half a credential pair stops the mail container at boot on purpose,
        # so writing one here would produce an install that never starts. Fall
        # back rather than fail the whole installation over it.
        echo "⚠️  Both a username and a password are needed. Skipping SES;"
        echo "    UNA will deliver directly. Add the keys to .env later."
        echo ""
    else
        SES_ENABLED=true
        echo "✅ Outbound mail will go through SES in $SES_REGION"
        echo ""
        echo "⚠️  Publish the SES DNS records BEFORE you start sending:"
        echo "    - SPF must include:amazonses.com"
        echo "    - Easy DKIM: verify this domain in the SES console and publish"
        echo "      the three CNAMEs it shows"
        echo "    Until both exist, DMARC fails for everything you send."
        echo ""
        echo "⚠️  A new SES account is in the sandbox and can only send to"
        echo "    addresses you have verified with Amazon."
        echo ""
    fi
fi

# ============================================
# Step 4: Create Configuration
# ============================================
echo "Step 4: Creating Configuration"
echo "------------------------------"

# Get server IP (force IPv4)
SERVER_IP=$(curl -4 -s ifconfig.me 2>/dev/null || curl -4 -s icanhazip.com 2>/dev/null || curl -s api.ipify.org 2>/dev/null || echo "YOUR_SERVER_IP")

# Rspamd controller password. Not prompted for: nobody types this, it just has
# to stop being the image default "q1" on the controller that owns /learnspam.
RSPAMD_PASSWORD=$(openssl rand -base64 24)

# Session signing secret. Not prompted for either: it signs the cookie that
# keeps a browser signed in, and it only has to be random and stay put.
SESSION_SECRET=$(openssl rand -base64 32)

# Web Push (VAPID) keypair. Also not prompted for.
#
# A VAPID pair is an ordinary P-256 key: the private key is the 32-byte
# scalar and the public key is the uncompressed point (0x04 || X || Y), both
# base64url with the padding stripped. `web-push generate-vapid-keys` does
# exactly this and needs Node, which a fresh server does not have -- openssl
# does, and install.sh already leans on it for the secrets above.
#
# Changing these later invalidates every push subscription in the database and
# every browser has to be asked again, so they are generated once, here.
VAPID_PEM=$(mktemp)
openssl ecparam -name prime256v1 -genkey -noout -out "$VAPID_PEM" 2>/dev/null
VAPID_PRIVATE_KEY=$(openssl ec -in "$VAPID_PEM" -outform DER 2>/dev/null \
  | tail -c +8 | head -c 32 | base64 | tr '+/' '-_' | tr -d '=')
VAPID_PUBLIC_KEY=$(openssl ec -in "$VAPID_PEM" -pubout -outform DER 2>/dev/null \
  | tail -c 65 | base64 | tr '+/' '-_' | tr -d '=')
rm -f "$VAPID_PEM"

# The outbound-relay block, either way. Answering no still writes the keys --
# commented out, with the values named -- because the person who needs them is
# the person whose mail is not arriving, and they should find them in .env
# rather than in a document.
if [ "$SES_ENABLED" = true ]; then
    RELAY_BLOCK=$(cat << RELAYEOF

# Outbound relay. Inbound port 25 is still required; this only changes where
# outgoing mail leaves from. Run 'docker compose up -d postfix' after editing.
# The username and password below are SES SMTP credentials, not an AWS key.
# The password is single-quoted because Compose interpolates \$name inside an
# unquoted .env value; keep the quotes if you edit it.
SMTP_RELAY_PROVIDER=ses
SMTP_RELAY_REGION=$SES_REGION
SMTP_RELAY_HOST=
SMTP_RELAY_PORT=587
SMTP_RELAY_USERNAME=$SES_USERNAME
SMTP_RELAY_PASSWORD='$SES_PASSWORD'
RELAYEOF
)
else
    RELAY_BLOCK=$(cat << 'RELAYEOF'

# Outbound relay (not configured -- UNA delivers straight to each recipient's
# mail server on port 25).
#
# Uncomment and fill these in if your provider blocks outbound 25 or your IP is
# blocklisted, then run 'docker compose up -d postfix'. Inbound port 25 is still
# required either way -- a relay only changes where outgoing mail leaves from.
#
# For SES, the username and password are SMTP credentials from the SES console
# (Account dashboard -> Create SMTP credentials), NOT an AWS access key. Publish
# an SPF include:amazonses.com and the three Easy DKIM CNAMEs before you switch
# this on, or DMARC fails for everything you send.
#
#SMTP_RELAY_PROVIDER=ses
#SMTP_RELAY_REGION=us-east-1
#SMTP_RELAY_HOST=
#SMTP_RELAY_PORT=587
#SMTP_RELAY_USERNAME=
# Single-quote the password if it contains a $ -- Compose interpolates $name
# inside an unquoted .env value and the relay then sees a truncated password.
#SMTP_RELAY_PASSWORD=
RELAYEOF
)
fi

# Create .env file
cat > .env << EOF
# UNA.Email Configuration
# Generated: $(date)

DOMAIN=$DOMAIN
MAIL_SUBDOMAIN=$MAIL_SUBDOMAIN
DB_PASSWORD=$DB_PASSWORD
RSPAMD_PASSWORD=$RSPAMD_PASSWORD
SESSION_SECRET=$SESSION_SECRET
VAPID_PUBLIC_KEY=$VAPID_PUBLIC_KEY
VAPID_PRIVATE_KEY=$VAPID_PRIVATE_KEY
VAPID_SUBJECT=mailto:admin@$DOMAIN
$RELAY_BLOCK

NODE_ENV=production
IMAGE_TAG=latest
GITHUB_REPOSITORY=roncanfil/una.email
EOF

chmod 600 .env

echo "✅ Created .env file"
echo "✅ Rspamd controller password: generated, in .env"
echo "✅ Session secret: generated, in .env"
echo "✅ Web Push VAPID keypair: generated, in .env"
if [ "$SES_ENABLED" = true ]; then
    echo "✅ Outbound relay: Amazon SES ($SES_REGION), in .env"
else
    echo "✅ Outbound mail: direct to each recipient (SMTP_RELAY_* commented in .env)"
fi

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

echo "⏳ Waiting for Postgres..."
PG_READY=""
for _ in $(seq 1 60); do
    if docker compose exec -T postgres pg_isready -U una_email > /dev/null 2>&1; then
        PG_READY="yes"
        break
    fi
    sleep 1
done

if [ -z "$PG_READY" ]; then
    echo "❌ Postgres did not become ready within 60 seconds."
    echo ""
    docker compose logs --tail 40 postgres
    exit 1
fi
echo "✅ Postgres ready"

# The web image's start command is `next start`. It does not run migrations and
# it does not wait for anything, so we wait for it ourselves before asking it
# to run Prisma.
echo "⏳ Waiting for the web container..."
WEB_READY=""
for _ in $(seq 1 60); do
    # wget: the web image has no curl.
    if docker compose exec -T web wget -q -O /dev/null http://localhost:3000 > /dev/null 2>&1; then
        WEB_READY="yes"
        break
    fi
    sleep 2
done

if [ -z "$WEB_READY" ]; then
    echo "❌ The web container did not respond within 120 seconds."
    echo ""
    docker compose logs --tail 40 web
    exit 1
fi
echo "✅ Web container ready"

echo "📋 Service status:"
docker compose ps --format "table {{.Name}}\t{{.Status}}"
echo ""

# ============================================
# Step 6: Initialize Database
# ============================================
echo "Step 6: Database Setup"
echo "----------------------"

# migrate deploy, never `db push`. The migrations are hand-authored -- generated
# search_vector columns and the Phase 2/3 data backfills are SQL that Prisma
# cannot derive from schema.prisma, and `db push` would skip all of it.
echo "🗄️  Applying database migrations..."
if docker compose exec -T web npx prisma migrate deploy; then
    echo "✅ Database ready"
else
    echo ""
    echo "❌ Database migration failed. See the output above."
    echo "   The stack is running but the schema is incomplete; fix the error"
    echo "   and re-run:  docker compose exec -T web npx prisma migrate deploy"
    echo "   Then finish setup with ./install.sh again."
    exit 1
fi
echo ""

# ============================================
# Step 7: Generate DKIM Key
# ============================================
echo "Step 7: Generating DKIM Key"
echo "---------------------------"

echo "🔑 Creating DKIM signing key..."

# Written on the host, into ./dkim, which both rspamd (read-only) and web
# (read-write) bind-mount. It used to be generated with `rspamadm dkim_keygen`
# inside the rspamd container, into a corner of the rspamd_data volume -- which
# no other container could see. The web app has to be able to write a key when
# an admin adds a second domain from Settings -> Domains, so the keys moved to
# a directory both containers share. update.sh copies an existing install's key
# out of the old volume.
#
# openssl on the host rather than in a container: install.sh already requires
# it (SESSION_SECRET, RSPAMD_PASSWORD) and the rspamd mount is read-only now.
mkdir -p dkim

DKIM_KEY="dkim/una.$DOMAIN.key"
DKIM_PUB="dkim/una.$DOMAIN.pub"

if [ -f "$DKIM_KEY" ]; then
    echo "✅ DKIM key already present -- keeping it"
else
    openssl genrsa -out "$DKIM_KEY" 2048 2>/dev/null
    echo "✅ DKIM key generated"
fi

openssl rsa -in "$DKIM_KEY" -pubout -out "$DKIM_PUB" 2>/dev/null

# 0640 on the key and 0644 on the public half, matching scripts/generate-dkim.sh
# in the source repo. World-readable is wrong for a signing key.
#
# The group matters as much as the mode: Rspamd reads the key off this bind
# mount as uid/gid 11333 (_rspamd in rspamd/rspamd:4.1), and on Linux the
# ownership a bind mount presents is the host's. A 0640 root:root key is one
# Rspamd cannot open -- which shows up as mail going out unsigned, with nothing
# in any log to say why.
chgrp 11333 "$DKIM_KEY" 2>/dev/null || chown :11333 "$DKIM_KEY" 2>/dev/null || \
    echo "⚠️  Could not give $DKIM_KEY to gid 11333 -- Rspamd may not be able to read it"
chmod 640 "$DKIM_KEY"
chmod 644 "$DKIM_PUB"

DKIM_PUBKEY=$(grep -v "PUBLIC KEY" "$DKIM_PUB" | tr -d '\n')

if [ -n "$DKIM_PUBKEY" ]; then
    DKIM_RECORD="v=DKIM1; k=rsa; p=$DKIM_PUBKEY"
else
    DKIM_RECORD="v=DKIM1; k=rsa; p=<run: openssl rsa -in $DKIM_KEY -pubout | grep -v '^-' | tr -d '\\n'>"
    echo "⚠️  Could not extract the public key automatically"
fi

# The same record as a file, so Settings -> Domains and this script leave the
# same three files behind for every domain.
cat > "dkim/una.$DOMAIN.dns.txt" << DKIMEOF
=================================================================
DKIM DNS Record for $DOMAIN
=================================================================

Add this TXT record to your DNS:

  Host/Name:  una._domainkey.$DOMAIN
  Type:       TXT
  Value:      $DKIM_RECORD

Full record for copy/paste (single line):
$DKIM_RECORD

=================================================================
DKIMEOF
chmod 644 "dkim/una.$DOMAIN.dns.txt"

# Bounce messages come from mail.$DOMAIN, and dkim_signing looks the key up by
# the From domain. A relative symlink, so it resolves inside the container too.
ln -sf "una.$DOMAIN.key" "dkim/una.mail.$DOMAIN.key" 2>/dev/null || true

# Rspamd reads the mount as its own user, so the directory has to be traversable
# and the key readable by it. Group-readable plus a world-executable directory
# is the least that achieves it without making the key world-readable.
chmod 755 dkim
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

Go to your domain registrar (Cloudflare, Namecheap, GoDaddy, etc.) and add these DNS records:

### 1. MX Record
Tells email servers where to deliver mail for your domain.

| Type | Host | Value | Priority |
|------|------|-------|----------|
| MX | @ | mail.$DOMAIN | 10 |

### 2. A Record$(if [ "$MAIL_SUBDOMAIN" != "mail" ]; then echo 's'; fi)
Point your hostname$(if [ "$MAIL_SUBDOMAIN" != "mail" ]; then echo 's'; fi) to your server.

$(if [ "$MAIL_SUBDOMAIN" = "mail" ]; then
echo "| Type | Host | Value |"
echo "|------|------|-------|"
echo "| A | mail | $SERVER_IP |"
echo ""
echo "Since your web interface and mail server share the same subdomain (mail.$DOMAIN),"
echo "only one A record is needed. It handles both SMTP (port 25) and HTTPS (port 443)."
else
echo "| Type | Host | Value | Purpose |"
echo "|------|------|-------|---------|"
echo "| A | mail | $SERVER_IP | Mail server (SMTP) |"
echo "| A | $MAIL_SUBDOMAIN | $SERVER_IP | Web interface |"
fi)

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

---

## Step 2: Set Up Reverse DNS (PTR Record)

Reverse DNS maps your server's IP address back to your hostname. This is essential for
email deliverability — most mail servers will reject or flag emails from servers without
a valid PTR record.

**Important:** This is NOT configured at your domain registrar. You must set it up at your
VPS or hosting provider's control panel.

| Server IP | PTR Value |
|-----------|-----------|
| $SERVER_IP | mail.$DOMAIN |

### How to set this up:
- **Vultr:** Server Settings → IPv4 → click "Reverse DNS" → enter \`mail.$DOMAIN\`
- **DigitalOcean:** Rename your Droplet to \`mail.$DOMAIN\` (PTR is set automatically from the hostname)
- **Hetzner:** Server → Networking → click the IP address → set Reverse DNS
- **Linode/Akamai:** Network tab → IP Addresses → Edit RDNS
- **Other providers:** Look for "Reverse DNS", "PTR Record", or "RDNS" in your server's network settings. Some providers require you to open a support ticket to configure this.

---

## Step 3: Verify DNS Records

After adding DNS records, wait 5-30 minutes for propagation, then verify:

\`\`\`bash
# Check MX record
dig MX $DOMAIN +short
\`\`\`
**Expected output:**
\`\`\`
10 mail.$DOMAIN.
\`\`\`

$(if [ "$MAIL_SUBDOMAIN" = "mail" ]; then
echo '\`\`\`bash'
echo "# Check A record"
echo "dig A mail.$DOMAIN +short"
echo '\`\`\`'
echo "**Expected output:**"
echo '\`\`\`'
echo "$SERVER_IP"
echo '\`\`\`'
else
echo '\`\`\`bash'
echo "# Check A records"
echo "dig A mail.$DOMAIN +short"
echo "dig A $MAIL_SUBDOMAIN.$DOMAIN +short"
echo '\`\`\`'
echo "**Expected output (both should return):**"
echo '\`\`\`'
echo "$SERVER_IP"
echo '\`\`\`'
fi)

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

\`\`\`bash
# Check PTR record
dig -x $SERVER_IP +short
\`\`\`
**Expected output:**
\`\`\`
mail.$DOMAIN.
\`\`\`

---

## Step 4: Get SSL Certificate

Run the following command to obtain a free SSL certificate from Let's Encrypt:

\`\`\`bash
./renew-ssl.sh
\`\`\`

This script will:
- Obtain an SSL certificate for \`$MAIL_SUBDOMAIN.$DOMAIN\`
- Configure HTTPS for the web interface (port 443)
- Configure TLS encryption for the mail server (SMTP)
- Display your DANE/TLSA hash for the next step

If a certificate already exists, it will attempt to renew it instead.

**Note:** DNS records must be properly configured and propagated before running this script,
otherwise the certificate request will fail.

---

## Step 5: Add DANE/TLSA DNS Record

DANE adds an extra layer of security by publishing your mail server's public key fingerprint
in DNS. This allows other mail servers to verify your certificate directly through DNS,
preventing man-in-the-middle attacks.

After running \`./renew-ssl.sh\` in the previous step, the script displayed your TLSA hash.
Now go back to your domain registrar and add this DNS record:

| Type | Host | Value |
|------|------|-------|
| TLSA | _25._tcp.mail | 3 1 1 <hash-displayed-by-renew-ssl.sh> |

You can retrieve the hash at any time by running:

\`\`\`bash
openssl x509 -in ./letsencrypt/etc/live/$MAIL_SUBDOMAIN.$DOMAIN/cert.pem -noout -pubkey | openssl pkey -pubin -outform DER | sha256sum
\`\`\`

**Note:** The TLSA hash is based on your certificate's public key, which stays the same
across certificate renewals. You only need to update this DNS record if you perform
a full reinstallation.

---

## Step 6: Access Your Email

Open your browser and go to:

**https://$MAIL_SUBDOMAIN.$DOMAIN**

You should see the UNA Email login page with a valid SSL certificate (green padlock).
Create your account, then go to **Settings** and create your first email address — you'll
need it for the next step.

---

## Step 7: Test Your Email Deliverability

Now that you have an email address, verify that everything is configured correctly:

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
