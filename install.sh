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

# A single DNS label: what goes to the left of the domain. Not a full hostname
# and not a bare dot -- `webmail`, not `webmail.example.com`.
validate_label() {
    local label=$1
    if [[ ! $label =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
        return 1
    fi
    return 0
}

# Two hostnames, two questions, because they are two different things and
# conflating them is what made the old single MAIL_SUBDOMAIN confusing.
#
# The SMTP one is the server's identity on the wire: the MX target, the name
# Postfix gives in HELO, and the name reverse DNS must return. `mail` is the
# default because every provider's rDNS documentation, every deliverability
# checker and every blocklist removal form assumes it. The label itself earns
# no deliverability points -- `mx` scores exactly the same -- but the PTR
# record has to agree with whatever is chosen here, and a mismatch is the most
# common reason a self-hosted server lands in spam.
read -p "Subdomain for the mail server (MX, HELO, PTR) [mail]: " SMTP_SUBDOMAIN
SMTP_SUBDOMAIN="${SMTP_SUBDOMAIN:-mail}"
if ! validate_label "$SMTP_SUBDOMAIN"; then
    echo "❌ Invalid subdomain. Use a single label such as: mail, mx, smtp"
    exit 1
fi
echo "✅ Mail server will identify as: $SMTP_SUBDOMAIN.$DOMAIN"
echo ""

read -p "Subdomain for web access [webmail]: " WEB_SUBDOMAIN
WEB_SUBDOMAIN="${WEB_SUBDOMAIN:-webmail}"
if ! validate_label "$WEB_SUBDOMAIN"; then
    echo "❌ Invalid subdomain. Use a single label such as: webmail, mail, app"
    exit 1
fi
echo "✅ Web UI will be at: https://$WEB_SUBDOMAIN.$DOMAIN"
echo ""

# Answering both the same is allowed and used to be the only option: one name
# serving SMTP on 25 and HTTPS on 443 is a normal arrangement, and it means one
# A record and one name on the certificate. Worth saying out loud so it reads
# as a choice rather than a mistake.
if [ "$SMTP_SUBDOMAIN" = "$WEB_SUBDOMAIN" ]; then
    echo "ℹ️  Both services share $SMTP_SUBDOMAIN.$DOMAIN — one A record covers"
    echo "   SMTP on port 25 and HTTPS on port 443."
    echo ""
fi

# ============================================
# Step 3: Database Password
# ============================================
echo "Step 3: Database Password"
echo "-------------------------"

# An .env from an earlier run of this script wins, and is not offered as a
# choice.
#
# This script is re-runnable by design -- every failure path above tells the
# operator to fix the problem and run it again -- but Postgres initialised its
# `una_email` role from whatever DB_PASSWORD was set the first time, and it
# keeps that password for the life of the volume. Generating a fresh one on a
# re-run writes a password the database does not have, and every container then
# fails to authenticate against a database that was working a minute earlier.
EXISTING_DB_PASSWORD=""
if [ -f .env ]; then
    EXISTING_DB_PASSWORD=$(grep -E '^[[:space:]]*DB_PASSWORD=.+' .env | head -1 | cut -d= -f2- | tr -d '"'"'"' ' || true)
fi

if [ -n "$EXISTING_DB_PASSWORD" ]; then
    DB_PASSWORD="$EXISTING_DB_PASSWORD"
    echo "✅ Reusing the database password already in .env"
    echo "   (Postgres keeps the password it was initialised with. To change it,"
    echo "    remove the postgres volume -- which deletes all mail -- or ALTER"
    echo "    the role and edit .env to match.)"
else
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
fi
echo ""

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

# Encrypts the outbound relay password in the database, so a dump on its own
# does not yield a live sending credential. Generated whether or not a relay is
# ever configured: it costs nothing, and the alternative is asking for it at
# the worst possible moment -- when mail has started bouncing and the operator
# is trying to switch to a relay in a hurry.
RELAY_KEY=$(openssl rand -base64 32)

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
# `tr -d '=\n'` -- the newline is not decoration.
#
# GNU coreutils base64 wraps its output at 76 columns. The public key is 87
# characters once the padding is stripped, so it arrived in .env as 76
# characters on one line and an orphan 11-character line after it. That orphan
# is not KEY=VALUE, so `source .env` tried to run it as a command:
#
#   .env: line 11: HURWceO8gXc: command not found
#
# which, under `set -e` in renew-ssl.sh, exited the script before it did
# anything. Docker Compose meanwhile read the truncated 76-character value and
# Web Push would have been quietly signing with a corrupt key. The private key
# is 43 characters and never wrapped, but it gets the same treatment so the two
# cannot drift.
VAPID_PEM=$(mktemp)
openssl ecparam -name prime256v1 -genkey -noout -out "$VAPID_PEM" 2>/dev/null
VAPID_PRIVATE_KEY=$(openssl ec -in "$VAPID_PEM" -outform DER 2>/dev/null \
  | tail -c +8 | head -c 32 | base64 | tr '+/' '-_' | tr -d '=\n')
VAPID_PUBLIC_KEY=$(openssl ec -in "$VAPID_PEM" -pubout -outform DER 2>/dev/null \
  | tail -c 65 | base64 | tr '+/' '-_' | tr -d '=\n')
rm -f "$VAPID_PEM"

# The outbound relay keys, always written and always commented out.
#
# They are no longer asked for at install time. Outbound delivery is configured
# from Settings -> Sending, which writes `relay_settings` and has the mail
# container apply it live -- because the moment that matters is not this one.
# It is three weeks in, when mail starts bouncing off a blocklist and the
# answer should not be an SSH session.
#
# These stay as the escape hatch, and they take precedence over the database
# wherever they are set: an install that was configured this way keeps working
# untouched, and an operator locked out of the web interface can still redirect
# outbound mail. Setting any of them makes Settings -> Sending read-only, which
# it says on the page.
RELAY_BLOCK=$(cat << 'RELAYEOF'

# Outbound relay (not configured -- UNA delivers straight to each recipient's
# mail server on port 25).
#
# You do not need to edit this file to use a relay. Settings -> Sending in the
# web interface configures one and applies it without a restart, and that is
# the supported route.
#
# Uncommenting these takes precedence over whatever the web interface has
# stored, and makes that page read-only. Use them when the web interface cannot
# be reached, or to pin a configuration that must not be changed from a
# browser. Run 'docker compose up -d postfix' after editing.
#
# Inbound port 25 is still required either way -- a relay only changes where
# outgoing mail leaves from.
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

# Create .env file
cat > .env << EOF
# UNA.Email Configuration
# Generated: $(date)

DOMAIN=$DOMAIN
SMTP_SUBDOMAIN=$SMTP_SUBDOMAIN
WEB_SUBDOMAIN=$WEB_SUBDOMAIN
DB_PASSWORD=$DB_PASSWORD
RSPAMD_PASSWORD=$RSPAMD_PASSWORD
SESSION_SECRET=$SESSION_SECRET
RELAY_KEY=$RELAY_KEY
VAPID_PUBLIC_KEY=$VAPID_PUBLIC_KEY
VAPID_PRIVATE_KEY=$VAPID_PRIVATE_KEY
VAPID_SUBJECT=mailto:admin@$DOMAIN
$RELAY_BLOCK

NODE_ENV=production
IMAGE_TAG=latest
GITHUB_REPOSITORY=roncanfil/una.email
EOF

chmod 600 .env

# Every consumer of this file -- `source .env` in renew-ssl.sh and update.sh,
# and Docker Compose's own parser -- assumes one KEY=VALUE per line. A value
# containing a newline silently becomes a line that is neither, and the error
# surfaces later and somewhere else. Check it here, where the fix is obvious.
if ! ( set -e; . ./.env ) > /dev/null 2>&1; then
    echo "❌ The .env just written cannot be sourced."
    echo ""
    echo "   A generated value probably contains a newline, which splits it"
    echo "   across two lines. The offending line:"
    echo ""
    ( . ./.env ) 2>&1 | head -3 | sed 's/^/     /'
    echo ""
    echo "   .env has been left in place for inspection."
    exit 1
fi

# Belt and braces: a line that is neither a comment, a blank, nor KEY=VALUE.
if grep -nvE '^[[:space:]]*(#|$)|^[A-Za-z_][A-Za-z0-9_]*=' .env > /dev/null 2>&1; then
    echo "❌ .env has a line that is not KEY=VALUE:"
    grep -nvE '^[[:space:]]*(#|$)|^[A-Za-z_][A-Za-z0-9_]*=' .env | head -3 | sed 's/^/     /'
    exit 1
fi

echo "✅ Created .env file"
echo "✅ Rspamd controller password: generated, in .env"
echo "✅ Session secret: generated, in .env"
echo "✅ Web Push VAPID keypair: generated, in .env"
echo "✅ Outbound relay key: generated, in .env"
echo "✅ Outbound mail: direct to each recipient (port 25)"
echo "   Change it in Settings -> Sending once you are signed in."

# Set permissions
chmod +x renew-ssl.sh 2>/dev/null || true

# Rspamd's optional override directory. Compose mounts it read-only, and Docker
# would otherwise create it root-owned on first `up` -- harmless, but it leaves
# an admin unable to drop a file in it without sudo. Empty is the normal state:
# UNA's Rspamd config lives in the image.
mkdir -p rspamd/override.d

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
# it does not wait for anything, so we wait for it ourselves.
#
# TWO waits, and the order between them and the migration is the whole point.
# Waiting for HTTP first deadlocks: the root route calls prisma.user.count(),
# so an un-migrated database makes it answer 500 forever, and the migration
# that would fix it is below. The installer would time out at 120 seconds
# having never migrated anything, and the logs it printed showed Prisma
# complaining that `public.users` does not exist -- which is the app behaving
# correctly against an empty schema, not a failure.
#
# So: wait for the container to be *running* (all `exec` needs), migrate, and
# only then ask for a page.
echo "⏳ Waiting for the web container to start..."
WEB_UP=""
for _ in $(seq 1 60); do
    if docker compose exec -T web true > /dev/null 2>&1; then
        WEB_UP="yes"
        break
    fi
    sleep 2
done

if [ -z "$WEB_UP" ]; then
    echo "❌ The web container did not start within 120 seconds."
    echo ""
    docker compose logs --tail 40 web
    exit 1
fi
echo "✅ Web container running"
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

# Next.js may hold a rendered error from a request made before the schema
# existed. A restart costs a few seconds and makes the check below mean what it
# says.
echo "🔄 Restarting web to pick up the new schema..."
docker compose restart web > /dev/null 2>&1 || true

echo "⏳ Waiting for the web interface..."
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
    echo "❌ The web container did not serve a page within 120 seconds."
    echo ""
    docker compose logs --tail 40 web
    exit 1
fi
echo "✅ Web interface ready"

echo "📋 Service status:"
docker compose ps --format "table {{.Name}}\t{{.Status}}"
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
# an admin presses Generate / Replace DKIM on Settings -> Domains, so the keys
# moved to a directory both containers share. update.sh copies an existing
# install's key out of the old volume.
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

# Bounce messages come from $SMTP_SUBDOMAIN.$DOMAIN, and dkim_signing looks the
# key up by the From domain. A relative symlink, so it resolves inside the
# container too. The name follows SMTP_SUBDOMAIN: point the MX at `mx` and it is
# mx.$DOMAIN that has to be signable, so the symlink and the second DKIM record
# in YOUR_SETUP.md below both have to move with it.
ln -sf "una.$DOMAIN.key" "dkim/una.$SMTP_SUBDOMAIN.$DOMAIN.key" 2>/dev/null || true

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

# cron runs with no working directory, so the crontab line in both guides needs
# the absolute path to this checkout rather than ./renew-ssl.sh. Defined here
# because YOUR_SETUP.md below is the first thing to use it -- it used to live
# further down next to the HTML page, which left the markdown's crontab line
# reading "/renew-ssl.sh".
INSTALL_PATH=$(pwd)

cat > YOUR_SETUP.md << EOF
# UNA Email Setup for $DOMAIN

Generated: $(date)
Server IP: $SERVER_IP

---

## Before You Start: Is This Domain Already In Use?

**Skip this if $DOMAIN is a brand-new domain with an empty DNS zone.**

If $DOMAIN already has a website or a mailbox somewhere else -- GoDaddy, Squarespace,
Wix, Google Workspace, Microsoft 365 -- UNA runs alongside it.

**Your website is not affected.** Nothing in this guide changes the A record for
$DOMAIN or www.$DOMAIN. Only $SMTP_SUBDOMAIN.$DOMAIN and $WEB_SUBDOMAIN.$DOMAIN point at
this server, and the certificate covers only those two names. Your site keeps loading
from wherever it is hosted now.

But three of the records in Step 1 are **single-value** records. Adding them next to
what is already published does not work -- it breaks both. Check what exists first:

\`\`\`bash
dig NS $DOMAIN +short                    # where your DNS actually lives
dig MX $DOMAIN +short                    # every line here must be removed
dig TXT $DOMAIN +short | grep -c v=spf1  # must end up as 1, never 2
dig TXT _dmarc.$DOMAIN +short            # if this answers, replace it
\`\`\`

### MX -- delete the existing records first

Mail for **all of** $DOMAIN moves to UNA. Leave your old provider's MX records in place
next to UNA's and inbound mail is split between two servers more or less at random --
some of it will never reach your UNA inbox. Remove every existing MX record on \`@\`
before adding the one in Step 1.

If you still need the messages in the old mailbox, export them **before** you switch the
MX. UNA is web-only and has no IMAP import.

### SPF -- merge into the existing record, never add a second

A domain may publish only **one** \`v=spf1\` record. Two of them is a permanent error
(\`permerror\`), and SPF then fails for *every* sender on your domain, the old host
included. If the \`grep -c\` above returned \`1\`, edit that record instead of adding
UNA's. An existing GoDaddy record like this:

\`\`\`
v=spf1 include:secureserver.net -all
\`\`\`

becomes:

\`\`\`
v=spf1 a:$SMTP_SUBDOMAIN.$DOMAIN ip4:$SERVER_IP mx include:secureserver.net ~all
\`\`\`

Use whichever \`include:\` terms your own record already has. Keep the \`all\` mechanism
last, and leave it as \`~all\` while you are testing.

### DMARC -- one record only

Same rule at \`_dmarc\`. If a DMARC record already exists, replace its value with the one
in Step 1 rather than publishing a second TXT record.

### DKIM -- safe to add

\`una._domainkey\` is scoped to the \`una\` selector, so it cannot collide with another
provider's DKIM key unless that provider also happens to use the selector \`una\`.

### Where do the records go?

"Your registrar" is shorthand. Records have to be added wherever your **nameservers**
point, which is not always the registrar -- a domain can be registered at GoDaddy while
DNS is served by Cloudflare or a site builder. The \`dig NS\` check above tells you which
control panel to open.

### If your DNS is on Cloudflare

Set \`$SMTP_SUBDOMAIN\` and \`$WEB_SUBDOMAIN\` to **DNS only** (grey cloud, not orange).
A proxied record breaks SMTP on port 25 completely, and serves visitors Cloudflare's
certificate instead of the one \`./renew-ssl.sh\` issues.

---

## Step 1: Add DNS Records

Add these wherever your nameservers point -- usually your registrar (GoDaddy, Namecheap,
Cloudflare, etc.), but not always. If this domain is already in use somewhere else, read
"Before You Start" above first.

### 1. MX Record
Tells email servers where to deliver mail for your domain.

| Type | Host | Value | Priority |
|------|------|-------|----------|
| MX | @ | $SMTP_SUBDOMAIN.$DOMAIN | 10 |

**Delete any existing MX records on \`@\` first.** Two providers' MX records side by side
split your inbound mail between them.

### 2. A Record$(if [ "$WEB_SUBDOMAIN" != "$SMTP_SUBDOMAIN" ]; then echo 's'; fi)
Point your hostname$(if [ "$WEB_SUBDOMAIN" != "$SMTP_SUBDOMAIN" ]; then echo 's'; fi) to your server.

$(if [ "$WEB_SUBDOMAIN" = "$SMTP_SUBDOMAIN" ]; then
echo "| Type | Host | Value |"
echo "|------|------|-------|"
echo "| A | $SMTP_SUBDOMAIN | $SERVER_IP |"
echo ""
echo "Since your web interface and mail server share the same subdomain ($SMTP_SUBDOMAIN.$DOMAIN),"
echo "only one A record is needed. It handles both SMTP (port 25) and HTTPS (port 443)."
else
echo "| Type | Host | Value | Purpose |"
echo "|------|------|-------|---------|"
echo "| A | $SMTP_SUBDOMAIN | $SERVER_IP | Mail server (SMTP) |"
echo "| A | $WEB_SUBDOMAIN | $SERVER_IP | Web interface |"
echo ""
echo "Both are required. The MX record above points at $SMTP_SUBDOMAIN.$DOMAIN, so that"
echo "name must resolve for mail to be delivered at all; $WEB_SUBDOMAIN.$DOMAIN is where"
echo "you sign in. Certbot validates both names over port 80."
fi)

### 3. SPF Record
Tells receivers which servers can send email for your domain.

| Type | Host | Value |
|------|------|-------|
| TXT | @ | v=spf1 a:$SMTP_SUBDOMAIN.$DOMAIN ip4:$SERVER_IP mx ~all |

**Only one \`v=spf1\` record is allowed per domain.** If you already have one, merge UNA's
sources into it instead of adding this as a second record -- see "Before You Start" above.

### 4. DKIM Records
Cryptographic signature for email authentication. You need TWO DKIM records:

| Type | Host | Value |
|------|------|-------|
| TXT | una._domainkey | $DKIM_RECORD |
| TXT | una._domainkey.$SMTP_SUBDOMAIN | $DKIM_RECORD |

**Note:** Both records use the same value. The second one is for bounce messages sent from $SMTP_SUBDOMAIN.$DOMAIN.

### 5. DMARC Record
Policy for handling authentication failures.

| Type | Host | Value |
|------|------|-------|
| TXT | _dmarc | v=DMARC1; p=none; adkim=s; aspf=s; rua=mailto:postmaster@$DOMAIN; ruf=mailto:postmaster@$DOMAIN; fo=1; pct=100 |

**One DMARC record only.** If \`_dmarc\` already has a value, replace it rather than adding
a second TXT record.

---

## Step 2: Set Up Reverse DNS (PTR Record)

Reverse DNS maps your server's IP address back to your hostname. This is essential for
email deliverability — most mail servers will reject or flag emails from servers without
a valid PTR record.

**Important:** This is NOT configured at your domain registrar. You must set it up at your
VPS or hosting provider's control panel.

| Server IP | PTR Value |
|-----------|-----------|
| $SERVER_IP | $SMTP_SUBDOMAIN.$DOMAIN |

### How to set this up:
- **Vultr:** Server Settings → IPv4 → click "Reverse DNS" → enter \`$SMTP_SUBDOMAIN.$DOMAIN\`
- **DigitalOcean:** Rename your Droplet to \`$SMTP_SUBDOMAIN.$DOMAIN\` (PTR is set automatically from the hostname)
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
10 $SMTP_SUBDOMAIN.$DOMAIN.
\`\`\`
More than one line here means an old provider's MX record is still published. Remove it,
or half your mail keeps going to the old server.

$(if [ "$WEB_SUBDOMAIN" = "$SMTP_SUBDOMAIN" ]; then
echo '\`\`\`bash'
echo "# Check A record"
echo "dig A $SMTP_SUBDOMAIN.$DOMAIN +short"
echo '\`\`\`'
echo "**Expected output:**"
echo '\`\`\`'
echo "$SERVER_IP"
echo '\`\`\`'
else
echo '\`\`\`bash'
echo "# Check A records"
echo "dig A $SMTP_SUBDOMAIN.$DOMAIN +short"
echo "dig A $WEB_SUBDOMAIN.$DOMAIN +short"
echo '\`\`\`'
echo "**Expected output (both should return):**"
echo '\`\`\`'
echo "$SERVER_IP"
echo '\`\`\`'
fi)

\`\`\`bash
# Check that there is exactly one SPF record
dig TXT $DOMAIN +short | grep -c v=spf1
\`\`\`
**Expected output:**
\`\`\`
1
\`\`\`
A \`2\` here means a second SPF record was added instead of merging. SPF fails for every
sender on your domain until it is back to one -- see "Before You Start" above.

\`\`\`bash
# Check the record itself
dig TXT $DOMAIN +short | grep v=spf1
\`\`\`
**Expected output:** the record you published, for example
\`\`\`
"v=spf1 a:$SMTP_SUBDOMAIN.$DOMAIN ip4:$SERVER_IP mx ~all"
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
$SMTP_SUBDOMAIN.$DOMAIN.
\`\`\`

---

## Step 4: Get SSL Certificate

Run the following command to obtain a free SSL certificate from Let's Encrypt:

\`\`\`bash
./renew-ssl.sh
\`\`\`

This script will:
- Obtain an SSL certificate covering \`$WEB_SUBDOMAIN.$DOMAIN\` and \`$SMTP_SUBDOMAIN.$DOMAIN\`
- Configure HTTPS for the web interface (port 443)
- Configure TLS encryption for the mail server (SMTP)
- Display your DANE/TLSA hash for the next step

If a certificate already exists, it will attempt to renew it instead.

**Save the hash it prints.** When the script finishes it outputs a 64-character hash -- the
fingerprint of your certificate's public key. You need it in Step 6. Copy it somewhere now;
you can always get it back with the command in that step, but it is easier to keep than to
re-derive.

**Note:** DNS records must be properly configured and propagated before running this script,
otherwise the certificate request will fail.

---

## Step 5: Keep the Certificate Renewing

Your certificate lasts 90 days. **Nothing renews it automatically** -- the installer does
not touch your crontab -- so add this yourself:

\`\`\`bash
sudo crontab -e
\`\`\`

Add one line:

\`\`\`
30 2 * * * $INSTALL_PATH/renew-ssl.sh --cron > /dev/null 2>&1
\`\`\`

Daily is right even for a 90-day certificate: \`--cron\` is the quiet mode and does nothing
until there are fewer than 30 days left.

On a minimal CentOS/AlmaLinux image cron is often not installed. Check, and start it if it
is missing:

\`\`\`bash
systemctl is-active crond || sudo dnf install -y cronie && sudo systemctl enable --now crond
sudo crontab -l
\`\`\`

On Debian/Ubuntu the package and the service are both called \`cron\`. Test the entry
without waiting for 2:30am -- it should exit 0 and do nothing:

\`\`\`bash
$INSTALL_PATH/renew-ssl.sh --cron; echo \$?
\`\`\`

---

## Step 6: Add DANE/TLSA DNS Record (optional)

DANE publishes your certificate's fingerprint in DNS so sending servers can verify it
without trusting a certificate authority. It needs DNSSEC on your domain -- without it,
TLSA records are ignored entirely.

After running \`./renew-ssl.sh\`, the script printed your TLSA hash. It looks like
\`3 1 1 <64 hex characters>\`.

**Most registrars ask for the parts separately**, not as one string. The \`3 1 1\` is three
separate settings and the hash is the value on its own -- do not paste \`3 1 1 <hash>\` into
the value box.

| Field | Value |
|-------|-------|
| Type | TLSA |
| Port | **25** -- not 443. This protects SMTP, and forms often suggest 443. |
| Protocol | _tcp |
| Name / Host | $SMTP_SUBDOMAIN -- just the label. Port and Protocol build the \`_25._tcp\` part. If the form wants one long name, use \`_25._tcp.$SMTP_SUBDOMAIN.$DOMAIN\`. |
| Certificate Usage | 3 (DANE-EE: the certificate itself, no CA involved) |
| Selector | 1 (match the public key, not the whole certificate) |
| Matching Type | 1 (SHA-256) |
| Value | The 64-character hash alone, with no \`3 1 1\` in front of it. |
| TTL | default |

**Watch the field order.** The wire format is Usage, Selector, Matching Type -- but many
registrar forms list them as Usage, Matching Type, Selector. Here all three are \`3 1 1\`
so it makes no difference, but do not fill them in top to bottom from the string out of
habit.

Some registrars take the whole record as one line instead. Then it is
\`_25._tcp.$SMTP_SUBDOMAIN.$DOMAIN TLSA 3 1 1 <hash>\`.

You can retrieve the hash at any time by running:

\`\`\`bash
openssl x509 -in ./letsencrypt/etc/live/$WEB_SUBDOMAIN.$DOMAIN/cert.pem -noout -pubkey | openssl pkey -pubin -outform DER | sha256sum
\`\`\`

Check it once published:

\`\`\`bash
dig TLSA _25._tcp.$SMTP_SUBDOMAIN.$DOMAIN +short
\`\`\`

A space in the middle of the hash in that output is only \`dig\` wrapping a long string --
the record is fine.

**Note:** The hash is your certificate's public key and survives renewals
(\`--reuse-key\`), so you only replace it after a full reinstall -- which does generate a
new key, and until you update this record, senders that check DANE will refuse your mail.

---

## Step 7: Access Your Email

Open your browser and go to:

**https://$WEB_SUBDOMAIN.$DOMAIN**

You should see the UNA Email login page with a valid SSL certificate (green padlock).
Create your account, then go to **Settings** and create your first email address — you'll
need it for the next step.

---

## Step 8: Test Your Email Deliverability

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

- **Web Interface:** https://$WEB_SUBDOMAIN.$DOMAIN
- **SMTP Server:** $SMTP_SUBDOMAIN.$DOMAIN (port 25)
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
# Step 8b: Generate the HTML setup guide
# ============================================
# The same content as YOUR_SETUP.md, as a page Nginx serves on port 80 at
# http://$SERVER_IP/dns-setup.
#
# Port 80 and an IP address, deliberately. Every record below has to be in DNS
# before https://$WEB_SUBDOMAIN.$DOMAIN resolves or a certificate can be
# issued, so a guide that lived inside the web app could only be read after you
# no longer needed it. ./web-root is already bind-mounted into the nginx
# container for ACME challenges, so writing here needs no new mount.
#
# Everything on the page is public by design -- the domain, the server's own IP
# and a DKIM *public* key are all things you are about to publish in DNS. No
# password, no private key, and nothing from the mail store.
# web-root/dns-setup, NOT web-root/setup: /setup is a route the web app
# serves -- it is where a fresh install creates the first admin account. An
# nginx location of the same name shadows it and makes the app unreachable.
echo "Step 8b: Generating Setup Page"
echo "------------------------------"

mkdir -p web-root/dns-setup

# One verification check, as its own copyable row.
#
# $1 label, $2 the command, $3 what to expect. The command goes into the
# data-copy attribute verbatim, so it must not contain a double quote -- none
# of the dig lines do, and a > or | is fine inside an attribute value.
verify_row() {
    printf '  <div class="field">\n    <div class="fname">%s</div>\n    <div class="fval"><div class="copyrow"><code>%s</code><button class="copy" data-copy="%s">copy</button></div><div class="muted" style="margin-top:4px">%s</div></div>\n  </div>\n' \
        "$1" "$2" "$2" "$3"
}

# What to look for BEFORE publishing anything: whether this zone already has an
# MX, an SPF record or a DMARC record from another provider. Those three are
# single-value -- a second one does not sit alongside the first, it breaks both
# -- so the page has to ask the question before it hands out records to paste.
# Independent of the one-name/two-name split below, hence built out here.
PRECHECK_COMMANDS="dig NS $DOMAIN +short                    # where your DNS actually lives
dig MX $DOMAIN +short                    # every line here must be removed
dig TXT $DOMAIN +short | grep -c v=spf1  # must end up as 1, never 2
dig TXT _dmarc.$DOMAIN +short            # if this answers, replace it"
# Single quotes only: this string is interpolated into a double-quoted HTML
# attribute (data-copy="..."), so a double quote here would close it early.
PRECHECK_ONELINE="dig NS $DOMAIN +short; dig MX $DOMAIN +short; dig TXT $DOMAIN +short | grep -c v=spf1; dig TXT _dmarc.$DOMAIN +short"

# The page's variable parts, built here rather than inline so the heredoc below
# stays readable: the A-record rows (one host or two), the dig commands, and
# the singular/plural of "record resolves".
if [ "$WEB_SUBDOMAIN" = "$SMTP_SUBDOMAIN" ]; then
    A_PLURAL=""
    A_VERB="s"
    A_RECORD_ROWS="      <tr>
        <td data-label=\"Type\">A</td><td data-label=\"Host\">$SMTP_SUBDOMAIN</td>
        <td data-label=\"Value\" class=\"val\"><div class=\"copyrow\"><code>$SERVER_IP</code><button class=\"copy\" data-copy=\"$SERVER_IP\">copy</button></div><div class=\"muted\">Mail and web share this name: SMTP on port 25, HTTPS on 443.</div></td>
      </tr>"
    VERIFY_COMMANDS="dig MX $DOMAIN +short          # expect: 10 $SMTP_SUBDOMAIN.$DOMAIN.
dig A $SMTP_SUBDOMAIN.$DOMAIN +short   # expect: $SERVER_IP
dig TXT $DOMAIN +short | grep -c v=spf1  # exactly 1, a 2 breaks SPF
dig TXT una._domainkey.$DOMAIN +short
dig -x $SERVER_IP +short        # expect: $SMTP_SUBDOMAIN.$DOMAIN."
    VERIFY_COMMANDS_ONELINE="dig MX $DOMAIN +short; dig A $SMTP_SUBDOMAIN.$DOMAIN +short; dig TXT $DOMAIN +short | grep -c v=spf1; dig TXT una._domainkey.$DOMAIN +short; dig -x $SERVER_IP +short"
    VERIFY_ROWS="$(verify_row "MX" "dig MX $DOMAIN +short" "expect: 10 $SMTP_SUBDOMAIN.$DOMAIN.")
$(verify_row "A record" "dig A $SMTP_SUBDOMAIN.$DOMAIN +short" "expect: $SERVER_IP")
$(verify_row "SPF" "dig TXT $DOMAIN +short | grep -c v=spf1" "expect: exactly 1 &mdash; a 2 breaks SPF for every sender on your domain")
$(verify_row "DKIM" "dig TXT una._domainkey.$DOMAIN +short" "expect: a long v=DKIM1 record")
$(verify_row "PTR" "dig -x $SERVER_IP +short" "expect: $SMTP_SUBDOMAIN.$DOMAIN.")"
else
    A_PLURAL="s"
    A_VERB=""
    A_RECORD_ROWS="      <tr>
        <td data-label=\"Type\">A</td><td data-label=\"Host\">$SMTP_SUBDOMAIN</td>
        <td data-label=\"Value\" class=\"val\"><div class=\"copyrow\"><code>$SERVER_IP</code><button class=\"copy\" data-copy=\"$SERVER_IP\">copy</button></div><div class=\"muted\">Mail server. The MX above points here, so mail cannot be delivered until this resolves.</div></td>
      </tr>
      <tr>
        <td data-label=\"Type\">A</td><td data-label=\"Host\">$WEB_SUBDOMAIN</td>
        <td data-label=\"Value\" class=\"val\"><div class=\"copyrow\"><code>$SERVER_IP</code><button class=\"copy\" data-copy=\"$SERVER_IP\">copy</button></div><div class=\"muted\">Web interface. Both names are validated when the certificate is issued.</div></td>
      </tr>"
    VERIFY_COMMANDS="dig MX $DOMAIN +short           # expect: 10 $SMTP_SUBDOMAIN.$DOMAIN.
dig A $SMTP_SUBDOMAIN.$DOMAIN +short    # expect: $SERVER_IP
dig A $WEB_SUBDOMAIN.$DOMAIN +short     # expect: $SERVER_IP
dig TXT $DOMAIN +short | grep -c v=spf1  # exactly 1, a 2 breaks SPF
dig TXT una._domainkey.$DOMAIN +short
dig -x $SERVER_IP +short         # expect: $SMTP_SUBDOMAIN.$DOMAIN."
    VERIFY_COMMANDS_ONELINE="dig MX $DOMAIN +short; dig A $SMTP_SUBDOMAIN.$DOMAIN +short; dig A $WEB_SUBDOMAIN.$DOMAIN +short; dig TXT $DOMAIN +short | grep -c v=spf1; dig TXT una._domainkey.$DOMAIN +short; dig -x $SERVER_IP +short"
    VERIFY_ROWS="$(verify_row "MX" "dig MX $DOMAIN +short" "expect: 10 $SMTP_SUBDOMAIN.$DOMAIN.")
$(verify_row "A &mdash; mail" "dig A $SMTP_SUBDOMAIN.$DOMAIN +short" "expect: $SERVER_IP")
$(verify_row "A &mdash; web" "dig A $WEB_SUBDOMAIN.$DOMAIN +short" "expect: $SERVER_IP")
$(verify_row "SPF" "dig TXT $DOMAIN +short | grep -c v=spf1" "expect: exactly 1 &mdash; a 2 breaks SPF for every sender on your domain")
$(verify_row "DKIM" "dig TXT una._domainkey.$DOMAIN +short" "expect: a long v=DKIM1 record")
$(verify_row "PTR" "dig -x $SERVER_IP +short" "expect: $SMTP_SUBDOMAIN.$DOMAIN.")"
fi


# Unquoted heredoc: $VARIABLES are substituted. So there are no backticks and
# no unescaped $ anywhere in the CSS or JS below -- a backtick would be command
# substitution and would break the page in ways that are tedious to find.
cat > web-root/dns-setup/index.html << HTMLEOF
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title>UNA Email setup - $DOMAIN</title>
<style>
  :root {
    color-scheme: light dark;
    --bg: #f6f7f9;
    --card: #ffffff;
    --ink: #17191c;
    --muted: #5c636e;
    --line: #e2e5ea;
    --accent: #2f6df6;
    --code-bg: #f1f3f6;
    --ok: #1a7f4b;
    --warn-bg: #fff6e5;
    --warn-line: #f0c674;
    --warn-ink: #6b4e00;
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --bg: #14161a;
      --card: #1c1f24;
      --ink: #e8eaed;
      --muted: #9aa2ae;
      --line: #2c313a;
      --accent: #6ea0ff;
      --code-bg: #23272e;
      --ok: #5fd39b;
      --warn-bg: #2a2313;
      --warn-line: #6b5a23;
      --warn-ink: #f0d99a;
    }
  }
  * { box-sizing: border-box; }
  body {
    margin: 0;
    padding: 32px 16px 96px;
    background: var(--bg);
    color: var(--ink);
    font: 15px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
  }
  .wrap { max-width: 860px; margin: 0 auto; }
  header { margin-bottom: 28px; }
  h1 { font-size: 26px; margin: 0 0 6px; letter-spacing: -0.02em; }
  .sub { color: var(--muted); font-size: 14px; }
  h2 {
    font-size: 17px; margin: 0 0 14px;
    display: flex; align-items: center; gap: 10px;
  }
  .step {
    background: var(--card);
    border: 1px solid var(--line);
    border-radius: 12px;
    padding: 20px;
    margin-bottom: 16px;
  }
  .num {
    flex: 0 0 auto;
    width: 24px; height: 24px; border-radius: 50%;
    background: var(--accent); color: #fff;
    font-size: 13px; font-weight: 600;
    display: grid; place-items: center;
  }
  .num.alert { background: var(--warn-line); color: var(--warn-ink); }
  .fields { margin: 12px 0; border: 1px solid var(--line); border-radius: 8px; overflow: hidden; }
  .field { display: flex; gap: 12px; padding: 9px 10px; border-bottom: 1px solid var(--line); align-items: flex-start; }
  .field:last-child { border-bottom: 0; }
  .fname { flex: 0 0 150px; font-size: 12px; text-transform: uppercase; letter-spacing: 0.04em; color: var(--muted); font-weight: 600; padding-top: 4px; }
  .fval { flex: 1 1 auto; min-width: 0; }
  @media (max-width: 560px) { .field { flex-direction: column; gap: 4px; } .fname { flex: none; padding-top: 0; } }
  details { margin-top: 10px; }
  summary {
    cursor: pointer; font-size: 14px; font-weight: 500;
    padding: 8px 10px; border: 1px solid var(--line); border-radius: 8px;
    background: var(--code-bg); list-style-position: inside;
  }
  summary:hover { border-color: var(--accent); color: var(--accent); }
  details[open] summary { margin-bottom: 12px; }
  h3 { font-size: 15px; margin: 20px 0 8px; }
  p { margin: 0 0 12px; }
  .muted { color: var(--muted); font-size: 14px; }
  table { width: 100%; border-collapse: collapse; margin: 12px 0; font-size: 14px; }
  th, td { text-align: left; padding: 9px 10px; border-bottom: 1px solid var(--line); vertical-align: top; }
  th { font-size: 12px; text-transform: uppercase; letter-spacing: 0.04em; color: var(--muted); font-weight: 600; }
  tr:last-child td { border-bottom: 0; }
  td.val { width: 100%; }
  .copyrow { display: flex; align-items: flex-start; gap: 8px; }
  code, .mono {
    font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
    font-size: 13px;
    background: var(--code-bg);
    padding: 3px 6px;
    border-radius: 5px;
    word-break: break-all;
    flex: 1 1 auto;
  }
  pre {
    background: var(--code-bg); border-radius: 8px; padding: 12px;
    overflow-x: auto; font-size: 13px; margin: 10px 0;
    font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  }
  button.copy {
    flex: 0 0 auto;
    border: 1px solid var(--line); background: var(--card); color: var(--muted);
    border-radius: 6px; padding: 4px 9px; font-size: 12px; cursor: pointer;
    font-family: inherit;
  }
  button.copy:hover { border-color: var(--accent); color: var(--accent); }
  button.copy.ok { border-color: var(--ok); color: var(--ok); }
  .note {
    background: var(--warn-bg); border: 1px solid var(--warn-line);
    color: var(--warn-ink);
    border-radius: 8px; padding: 12px 14px; font-size: 14px; margin: 12px 0;
  }
  .note strong { font-weight: 600; }
  ul { margin: 10px 0; padding-left: 20px; }
  li { margin-bottom: 5px; }
  footer { color: var(--muted); font-size: 13px; text-align: center; margin-top: 28px; }
  a { color: var(--accent); }
  @media (max-width: 560px) {
    table, thead, tbody, th, td, tr { display: block; }
    thead { display: none; }
    td { border-bottom: 0; padding: 4px 0; }
    tr { border-bottom: 1px solid var(--line); padding: 10px 0; }
    td::before { content: attr(data-label); display: block; font-size: 11px; text-transform: uppercase; color: var(--muted); letter-spacing: 0.04em; }
  }
</style>
</head>
<body>
<div class="wrap">

<header>
  <h1>UNA Email setup</h1>
  <div class="sub">$DOMAIN &middot; server $SERVER_IP &middot; generated $(date)</div>
</header>

<div class="note">
  This page is served over plain HTTP from your server's IP, because none of it
  works until the DNS below exists. Everything on it is public information you
  are about to publish in DNS. Once your certificate is issued it is also at
  <a href="https://$WEB_SUBDOMAIN.$DOMAIN/dns-setup">https://$WEB_SUBDOMAIN.$DOMAIN/dns-setup</a>.
</div>

<section class="step" id="s0">
  <h2><span class="num alert">0</span> Already using this domain elsewhere?</h2>
  <p class="muted">If $DOMAIN is a brand-new domain with an empty DNS zone, skip
     this and start at step 1.</p>
  <details>
  <summary>Open this if $DOMAIN already has a website or email somewhere</summary>
  <p>If $DOMAIN already has a website or a mailbox somewhere else &mdash; GoDaddy,
     Squarespace, Wix, Google Workspace, Microsoft&nbsp;365 &mdash; UNA runs alongside it.</p>
  <p><strong>Your website is not affected.</strong> Nothing on this page changes the A
     record for $DOMAIN or www.$DOMAIN. Only $SMTP_SUBDOMAIN.$DOMAIN and
     $WEB_SUBDOMAIN.$DOMAIN point at this server, and the certificate covers only those
     two names. Your site keeps loading from wherever it is hosted now.</p>
  <p>But three of the records in step 1 are <strong>single-value</strong> records. Adding
     them next to what is already published does not work &mdash; it breaks both. Check
     what exists first:</p>
  <pre>$PRECHECK_COMMANDS</pre>
  <div class="copyrow"><span class="mono">copy all checks</span><button class="copy" data-copy="$PRECHECK_ONELINE">copy</button></div>

  <h3>MX &mdash; delete the existing records first</h3>
  <p>Mail for <strong>all of</strong> $DOMAIN moves to UNA. Leave your old provider's MX
     records in place next to UNA's and inbound mail is split between two servers more or
     less at random &mdash; some of it will never reach your UNA inbox. Remove every
     existing MX record on <code>@</code> before adding the one in step 1.</p>
  <p>If you still need the messages in the old mailbox, export them <strong>before</strong>
     you switch the MX. UNA is web-only and has no IMAP import.</p>

  <h3>SPF &mdash; merge, never add a second record</h3>
  <p>A domain may publish only <strong>one</strong> <code>v=spf1</code> record. Two of them
     is a permanent error, and SPF then fails for <em>every</em> sender on your domain, the
     old host included. If the count above came back as 1, edit that record instead of
     adding UNA's. An existing GoDaddy record like this:</p>
  <pre>v=spf1 include:secureserver.net -all</pre>
  <p>becomes:</p>
  <div class="copyrow"><code>v=spf1 a:$SMTP_SUBDOMAIN.$DOMAIN ip4:$SERVER_IP mx include:secureserver.net ~all</code><button class="copy" data-copy="v=spf1 a:$SMTP_SUBDOMAIN.$DOMAIN ip4:$SERVER_IP mx include:secureserver.net ~all">copy</button></div>
  <p class="muted">Use whichever <code>include:</code> terms your own record already has.
     Keep the <code>all</code> mechanism last, and leave it as <code>~all</code> while you
     are testing.</p>

  <h3>DMARC &mdash; one record only</h3>
  <p>Same rule at <code>_dmarc</code>. If a DMARC record already exists, replace its value
     with the one in step 1 rather than publishing a second TXT record.</p>

  <h3>DKIM &mdash; safe to add</h3>
  <p><code>una._domainkey</code> is scoped to the <code>una</code> selector, so it cannot
     collide with another provider's DKIM key unless that provider also happens to use the
     selector <code>una</code>.</p>

  <h3>Where do the records go?</h3>
  <p>&ldquo;Your registrar&rdquo; is shorthand. Records have to be added wherever your
     <strong>nameservers</strong> point, which is not always the registrar &mdash; a domain
     can be registered at GoDaddy while DNS is served by Cloudflare or a site builder. The
     <code>dig NS</code> check above tells you which control panel to open.</p>

  <h3>If your DNS is on Cloudflare</h3>
  <p>Set <code>$SMTP_SUBDOMAIN</code> and <code>$WEB_SUBDOMAIN</code> to
     <strong>DNS only</strong> (grey cloud, not orange). A proxied record breaks SMTP on
     port 25 completely, and serves visitors Cloudflare's certificate instead of the one
     <code>./renew-ssl.sh</code> issues.</p>
  </details>
</section>

<section class="step" id="s1">
  <h2><span class="num">1</span> DNS records</h2>
  <p class="muted">Add these wherever your nameservers point &mdash; usually your registrar
     (GoDaddy, Namecheap, Cloudflare&hellip;), but not always.</p>
  <table>
    <thead><tr><th>Type</th><th>Host</th><th>Value</th></tr></thead>
    <tbody>
      <tr>
        <td data-label="Type">MX</td><td data-label="Host">@</td>
        <td data-label="Value" class="val"><div class="copyrow"><code>$SMTP_SUBDOMAIN.$DOMAIN</code><button class="copy" data-copy="$SMTP_SUBDOMAIN.$DOMAIN">copy</button></div><div class="muted">Priority 10. Delete any existing MX records on @ first &mdash; two providers side by side split your inbound mail.</div></td>
      </tr>
$A_RECORD_ROWS
      <tr>
        <td data-label="Type">TXT</td><td data-label="Host">@</td>
        <td data-label="Value" class="val"><div class="copyrow"><code>v=spf1 a:$SMTP_SUBDOMAIN.$DOMAIN ip4:$SERVER_IP mx ~all</code><button class="copy" data-copy="v=spf1 a:$SMTP_SUBDOMAIN.$DOMAIN ip4:$SERVER_IP mx ~all">copy</button></div><div class="muted">SPF. Only one v=spf1 record is allowed per domain &mdash; if you already have one, merge into it rather than adding this.</div></td>
      </tr>
      <tr>
        <td data-label="Type">TXT</td><td data-label="Host">una._domainkey</td>
        <td data-label="Value" class="val"><div class="copyrow"><code>$DKIM_RECORD</code><button class="copy" data-copy="$DKIM_RECORD">copy</button></div><div class="muted">DKIM</div></td>
      </tr>
      <tr>
        <td data-label="Type">TXT</td><td data-label="Host">una._domainkey.$SMTP_SUBDOMAIN</td>
        <td data-label="Value" class="val"><div class="copyrow"><code>$DKIM_RECORD</code><button class="copy" data-copy="$DKIM_RECORD">copy</button></div><div class="muted">The same value again. Bounce messages are sent from $SMTP_SUBDOMAIN.$DOMAIN and are signed with this key.</div></td>
      </tr>
      <tr>
        <td data-label="Type">TXT</td><td data-label="Host">_dmarc</td>
        <td data-label="Value" class="val"><div class="copyrow"><code>v=DMARC1; p=none; adkim=s; aspf=s; rua=mailto:postmaster@$DOMAIN; ruf=mailto:postmaster@$DOMAIN; fo=1; pct=100</code><button class="copy" data-copy="v=DMARC1; p=none; adkim=s; aspf=s; rua=mailto:postmaster@$DOMAIN; ruf=mailto:postmaster@$DOMAIN; fo=1; pct=100">copy</button></div><div class="muted">DMARC. One record only; replace an existing _dmarc value rather than adding a second.</div></td>
      </tr>
    </tbody>
  </table>
</section>

<section class="step" id="s2">
  <h2><span class="num">2</span> Reverse DNS (PTR)</h2>
  <p>Set at your <strong>VPS provider</strong>, not your registrar. Without it most
     large providers will treat your mail as suspect.</p>
  <!-- Two values, so a table is the wrong shape for it: td.val is width:100%,
       which collapsed the "Server IP" column to min-content and crushed it
       against the PTR value. A stacked field list reads better here and at
       phone width. -->
  <div class="fields">
    <div class="field">
      <div class="fname">Server IP</div>
      <div class="fval"><div class="copyrow"><code>$SERVER_IP</code><button class="copy" data-copy="$SERVER_IP">copy</button></div></div>
    </div>
    <div class="field">
      <div class="fname">PTR value</div>
      <div class="fval"><div class="copyrow"><code>$SMTP_SUBDOMAIN.$DOMAIN</code><button class="copy" data-copy="$SMTP_SUBDOMAIN.$DOMAIN">copy</button></div></div>
    </div>
  </div>
  <ul>
    <li><strong>Vultr</strong> &mdash; Server Settings &rarr; IPv4 &rarr; Reverse DNS</li>
    <li><strong>DigitalOcean</strong> &mdash; rename the Droplet to $SMTP_SUBDOMAIN.$DOMAIN; PTR follows the hostname</li>
    <li><strong>Hetzner</strong> &mdash; Server &rarr; Networking &rarr; click the IP &rarr; Reverse DNS</li>
    <li><strong>Linode/Akamai</strong> &mdash; Network &rarr; IP Addresses &rarr; Edit RDNS</li>
    <li>Others: look for &ldquo;Reverse DNS&rdquo;, &ldquo;PTR&rdquo; or &ldquo;RDNS&rdquo;. Some require a support ticket.</li>
  </ul>
</section>

<section class="step" id="s3">
  <h2><span class="num">3</span> Verify propagation</h2>
  <p class="muted">Wait 5&ndash;30 minutes, then run these from any machine. Each
     one is copyable on its own, so you can work through them and see which
     record is not there yet.</p>
  <div class="fields">
$VERIFY_ROWS
  </div>
  <div class="copyrow" style="margin-top:14px"><span class="mono">Run them all at once</span><button class="copy" data-copy="$VERIFY_COMMANDS_ONELINE">copy all</button></div>
</section>

<section class="step" id="s4">
  <h2><span class="num">4</span> SSL certificate</h2>
  <p>Once the A record$A_PLURAL resolve$A_VERB, run this on the server:</p>
  <div class="copyrow"><code>cd ~/una.email-install &amp;&amp; ./renew-ssl.sh</code><button class="copy" data-copy="cd ~/una.email-install &amp;&amp; ./renew-ssl.sh">copy</button></div>
  <div class="note" style="margin-top:12px">
    <strong>Save the hash it prints.</strong> When the script finishes it outputs
    a 64-character hash, the fingerprint of your certificate's public key. You
    need it in step 6. Copy it somewhere now &mdash; you can always get it back
    with the command in step 6, but it is easier to keep than to re-derive.
  </div>
  <p class="muted" style="margin-top:12px">One certificate is issued covering
     <strong>$WEB_SUBDOMAIN.$DOMAIN</strong> and <strong>$SMTP_SUBDOMAIN.$DOMAIN</strong>.
     Both names are validated over port 80, and the same certificate is used by
     Nginx on 443 and by Postfix for STARTTLS on 25. Let's Encrypt allows 5
     certificates per domain per week.</p>
</section>

<section class="step" id="s5">
  <h2><span class="num">5</span> Keep the certificate renewing</h2>
  <p>Your certificate lasts 90 days and <strong>nothing renews it
     automatically</strong> &mdash; the installer does not touch your crontab.
     Three commands, on the server:</p>

  <div class="fields">
    <div class="field">
      <div class="fname">1. Is cron running?</div>
      <div class="fval">
        <div class="copyrow"><code>systemctl is-active crond</code><button class="copy" data-copy="systemctl is-active crond">copy</button></div>
        <div class="muted" style="margin-top:4px">Prints <code>active</code> if it is. On a
          minimal CentOS/AlmaLinux image it often is not installed &mdash; if so, install it:</div>
        <div class="copyrow" style="margin-top:6px"><code>sudo dnf install -y cronie &amp;&amp; sudo systemctl enable --now crond</code><button class="copy" data-copy="sudo dnf install -y cronie &amp;&amp; sudo systemctl enable --now crond">copy</button></div>
        <div class="muted" style="margin-top:4px">On Debian/Ubuntu the package and the service
          are both called <code>cron</code>.</div>
      </div>
    </div>

    <div class="field">
      <div class="fname">2. Open the crontab</div>
      <div class="fval">
        <div class="copyrow"><code>sudo crontab -e</code><button class="copy" data-copy="sudo crontab -e">copy</button></div>
        <div class="muted" style="margin-top:4px">Opens an editor. If it asks which one, pick nano.</div>
      </div>
    </div>

    <div class="field">
      <div class="fname">3. Add this line</div>
      <div class="fval">
        <div class="copyrow"><code>30 2 * * * $INSTALL_PATH/renew-ssl.sh --cron &gt; /dev/null 2&gt;&amp;1</code><button class="copy" data-copy="30 2 * * * $INSTALL_PATH/renew-ssl.sh --cron > /dev/null 2>&amp;1">copy</button></div>
        <div class="muted" style="margin-top:4px">Paste it on its own line, then save and exit.
          Daily is right even for a 90-day certificate: <code>--cron</code> is the quiet mode and
          does nothing until fewer than 30 days remain.</div>
      </div>
    </div>
  </div>

  <p class="muted">Check it took, and test the entry without waiting for 2:30am
     &mdash; it should exit 0 and do nothing:</p>
  <div class="copyrow"><code>sudo crontab -l</code><button class="copy" data-copy="sudo crontab -l">copy</button></div>
  <div class="copyrow" style="margin-top:6px"><code>$INSTALL_PATH/renew-ssl.sh --cron; echo \$?</code><button class="copy" data-copy="$INSTALL_PATH/renew-ssl.sh --cron; echo \$?">copy</button></div>
</section>

<section class="step" id="s6">
  <h2><span class="num">6</span> DANE / TLSA (optional)</h2>
  <p>DANE publishes your certificate's fingerprint in DNS so sending servers can
     verify it without trusting a certificate authority. It needs DNSSEC on your
     domain &mdash; without it, TLSA records are ignored.</p>
  <p><code>./renew-ssl.sh</code> prints the hash when it finishes. It looks like
     <code>3 1 1 &lt;64 hex characters&gt;</code>.</p>

  <div class="note">
    <strong>Most registrars ask for the parts separately</strong>, not as one
    string. The <code>3 1 1</code> is three separate settings, and the hash is
    the value on its own &mdash; do not paste <code>3 1 1 &lt;hash&gt;</code>
    into the value box.
  </div>

  <table>
    <thead><tr><th>Field</th><th>Value</th></tr></thead>
    <tbody>
      <tr><td data-label="Field">Type</td><td data-label="Value"><code>TLSA</code></td></tr>
      <tr>
        <td data-label="Field">Port</td>
        <td data-label="Value" class="val"><div class="copyrow"><code>25</code><button class="copy" data-copy="25">copy</button></div><div class="muted">Not 443. This protects SMTP, and forms often suggest 443.</div></td>
      </tr>
      <tr><td data-label="Field">Protocol</td><td data-label="Value"><code>_tcp</code></td></tr>
      <tr>
        <td data-label="Field">Name / Host</td>
        <td data-label="Value" class="val"><div class="copyrow"><code>$SMTP_SUBDOMAIN</code><button class="copy" data-copy="$SMTP_SUBDOMAIN">copy</button></div><div class="muted">Just the label. Port and Protocol build the <code>_25._tcp</code> part for you. If the form wants one long name instead, use <code>_25._tcp.$SMTP_SUBDOMAIN.$DOMAIN</code>.</div></td>
      </tr>
      <tr><td data-label="Field">Certificate Usage</td><td data-label="Value"><code>3</code><div class="muted">DANE-EE: the certificate itself, no CA involved.</div></td></tr>
      <tr><td data-label="Field">Selector</td><td data-label="Value"><code>1</code><div class="muted">Match the public key, not the whole certificate.</div></td></tr>
      <tr><td data-label="Field">Matching Type</td><td data-label="Value"><code>1</code><div class="muted">SHA-256.</div></td></tr>
      <tr>
        <td data-label="Field">Value / Certificate Association Data</td>
        <td data-label="Value"><code>the 64-character hash from renew-ssl.sh</code><div class="muted">The hash alone. No <code>3 1 1</code> in front of it.</div></td>
      </tr>
      <tr><td data-label="Field">TTL</td><td data-label="Value"><code>default</code></td></tr>
    </tbody>
  </table>

  <div class="note">
    <strong>Watch the field order.</strong> The wire format is Usage, Selector,
    Matching Type &mdash; but many registrar forms list them as Usage, Matching
    Type, Selector. Here all three are <code>3 1 1</code> so it makes no
    difference, but do not fill them in top to bottom from the string out of
    habit.
  </div>

  <p>Some registrars take the whole record as one line instead. Then it is
     the following, with your saved hash in place of &lt;hash&gt;:</p>
  <div class="copyrow"><code>_25._tcp.$SMTP_SUBDOMAIN.$DOMAIN TLSA 3 1 1 &lt;hash&gt;</code><button class="copy" data-copy="_25._tcp.$SMTP_SUBDOMAIN.$DOMAIN TLSA 3 1 1 &lt;hash&gt;">copy</button></div>

  <p style="margin-top:12px">Check it once published:</p>
  <div class="copyrow"><code>dig TLSA _25._tcp.$SMTP_SUBDOMAIN.$DOMAIN +short</code><button class="copy" data-copy="dig TLSA _25._tcp.$SMTP_SUBDOMAIN.$DOMAIN +short">copy</button></div>
  <p class="muted" style="margin-top:12px">A space in the middle of the hash in
     that output is only <code>dig</code> wrapping a long string &mdash; the
     record is fine. The hash is the certificate's public key and survives
     renewals (<code>--reuse-key</code>), so you only replace it after a full
     reinstall &mdash; which does generate a new key, and until you update this
     record, senders that check DANE will refuse your mail.</p>
</section>

<section class="step" id="s7">
  <h2><span class="num">7</span> Sign in and test</h2>
  <p>Open <a href="https://$WEB_SUBDOMAIN.$DOMAIN">https://$WEB_SUBDOMAIN.$DOMAIN</a>.
     The first screen creates your <em>sign-in</em> &mdash; the admin login for
     this install, not a mailbox, and nothing is delivered to it. Once you are
     in, create your first mailbox under Settings &rarr; Accounts. Mail sent to
     an address with no mailbox is refused.</p>
  <p>Then send a message to <a href="https://mail-tester.com/">mail-tester.com</a>
     &mdash; a few sentences of ordinary text, not one word &mdash; and check the
     score. SPF, DKIM, DMARC, PTR and blacklists should all be green. Below 8,
     the report names the record that is wrong. You get 3 free tests a day.</p>
</section>

<footer>
  Generated by install.sh &middot; also on the server as
  <span class="mono">YOUR_SETUP.md</span>
</footer>

</div>
<script>
// No template literals and no backticks anywhere: this file is written by a
// bash heredoc that would treat them as command substitution.
(function () {
  // navigator.clipboard is undefined on plain HTTP, which is exactly how this
  // page is served before a certificate exists. The textarea fallback is the
  // only thing that works here, so it is not dead code.
  function copyText(text) {
    if (navigator.clipboard && window.isSecureContext) {
      return navigator.clipboard.writeText(text);
    }
    return new Promise(function (resolve, reject) {
      var ta = document.createElement('textarea');
      ta.value = text;
      ta.setAttribute('readonly', '');
      ta.style.position = 'fixed';
      ta.style.top = '-1000px';
      document.body.appendChild(ta);
      ta.select();
      var ok = false;
      try { ok = document.execCommand('copy'); } catch (e) { ok = false; }
      document.body.removeChild(ta);
      ok ? resolve() : reject(new Error('copy failed'));
    });
  }

  document.querySelectorAll('button.copy').forEach(function (btn) {
    btn.addEventListener('click', function () {
      copyText(btn.getAttribute('data-copy')).then(function () {
        var old = btn.textContent;
        btn.textContent = 'copied';
        btn.classList.add('ok');
        setTimeout(function () {
          btn.textContent = old;
          btn.classList.remove('ok');
        }, 1400);
      }, function () {
        btn.textContent = 'select it';
      });
    });
  });

})();
</script>
</body>
</html>
HTMLEOF

chmod 644 web-root/dns-setup/index.html
chmod 755 web-root web-root/dns-setup

echo "✅ Created the setup page"
echo ""

# ============================================
# Installation Complete
# ============================================
echo ""
echo "=========================================="
echo "     ✨ Installation Complete! ✨"
echo "=========================================="
echo ""
echo "📄 Your personalized setup guide is ready. Open it in a browser:"
echo ""
echo "   http://$SERVER_IP/dns-setup"
echo ""
echo "   Also on the server as YOUR_SETUP.md, if you prefer to read it here."
echo ""
