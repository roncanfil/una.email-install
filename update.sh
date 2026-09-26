#!/bin/bash

# UNA.Email Update Script
# Safely updates UNA Email with automatic backup and rollback

set -e

echo ""
echo "=========================================="
echo "       UNA.Email Update"
echo "=========================================="
echo ""

# Check if installed
if [ ! -f .env ]; then
    echo "❌ No .env file found."
    echo "   Is UNA Email installed in this directory?"
    exit 1
fi

# ============================================
# Step 1: Update This Repository
# ============================================
# docker compose pull only updates the images. Everything else that makes the
# product work -- docker-compose.yml, this script -- is a file on disk in this
# checkout, and without a git pull none of it ever reaches the server. The
# Rspamd and Nginx configuration used to be in that list; it ships inside their
# images now, so `docker compose pull` is what moves it.
#
# UNA_UPDATE_REEXEC: bash reads a script incrementally as it executes, so a
# pull that rewrites update.sh underneath a running update.sh would run a
# spliced mixture of the two. When the pull changes this file we re-exec the
# new copy from the top and set this variable so the new process skips the
# pull it has already done.
if [ -z "${UNA_UPDATE_REEXEC:-}" ]; then
    echo "Step 1: Updating UNA Email files"
    echo "--------------------------------"

    if [ ! -d .git ]; then
        echo "❌ This directory is not a git checkout."
        echo ""
        echo "   update.sh needs to pull the latest compose file and scripts,"
        echo "   not just the container images. Re-install from git:"
        echo ""
        echo "     git clone https://github.com/roncanfil/una.email-install.git"
        echo ""
        echo "   and copy your existing .env into the new checkout."
        exit 1
    fi

    SELF_BEFORE=$(git rev-parse HEAD:update.sh 2>/dev/null || echo none)

    echo "⬇️  Pulling latest UNA Email files..."
    if ! git pull --ff-only; then
        echo ""
        echo "❌ git pull failed."
        echo ""
        echo "   If you have local edits to tracked files, stash or revert them:"
        echo "     git stash            # keep them"
        echo "     git checkout -- .    # discard them"
        echo "   then run ./update.sh again. Your .env is not tracked and is safe."
        exit 1
    fi
    echo "✅ Files updated"
    echo ""

    SELF_AFTER=$(git rev-parse HEAD:update.sh 2>/dev/null || echo none)
    if [ "$SELF_BEFORE" != "$SELF_AFTER" ]; then
        echo "🔄 update.sh itself changed — restarting with the new version..."
        echo ""
        export UNA_UPDATE_REEXEC=1
        exec bash "$0" "$@"
    fi
fi

# ============================================
# Step 2: Check Configuration
# ============================================
echo "Step 2: Checking Configuration"
echo "------------------------------"

# RSPAMD_PASSWORD became required: docker-compose.yml refuses to start without
# it. Installs made before it existed have no such line, so add one. Only ever
# append -- never rewrite DOMAIN, DB_PASSWORD or anything else the customer set.
if grep -qE '^[[:space:]]*RSPAMD_PASSWORD=.+' .env; then
    echo "✅ RSPAMD_PASSWORD present"
elif grep -qE '^[[:space:]]*RSPAMD_PASSWORD=[[:space:]]*$' .env; then
    echo "❌ RSPAMD_PASSWORD is present but empty in .env."
    echo "   Set a value (or delete the empty line and re-run this script):"
    echo "     echo \"RSPAMD_PASSWORD=\$(openssl rand -base64 24)\" >> .env"
    exit 1
else
    printf '\n# Rspamd controller password (added by update.sh)\nRSPAMD_PASSWORD=%s\n' \
        "$(openssl rand -base64 24)" >> .env
    echo "✅ added RSPAMD_PASSWORD to .env"
fi

# SESSION_SECRET became required with Phase 5 (sign-in). Same shape as above:
# compose refuses to start without it, and an install made before sign-in
# existed has no such line. Generating one here is safe -- there are no
# sessions to invalidate on an install that has never had any.
if grep -qE '^[[:space:]]*SESSION_SECRET=.+' .env; then
    echo "✅ SESSION_SECRET present"
elif grep -qE '^[[:space:]]*SESSION_SECRET=[[:space:]]*$' .env; then
    echo "❌ SESSION_SECRET is present but empty in .env."
    echo "   Set a value (or delete the empty line and re-run this script):"
    echo "     echo \"SESSION_SECRET=\$(openssl rand -base64 32)\" >> .env"
    exit 1
else
    printf '\n# Session signing secret (added by update.sh)\nSESSION_SECRET=%s\n' \
        "$(openssl rand -base64 32)" >> .env
    echo "✅ added SESSION_SECRET to .env"
fi

# RELAY_KEY became required when outbound delivery became configurable from
# Settings -> Sending. It encrypts the relay password in the database, so a
# dump on its own does not yield a live sending credential.
#
# Safe to generate here on any install: it can only decrypt a password that was
# encrypted with it, and an install that has never configured a relay from the
# UI has none. An install using SMTP_RELAY_* in .env is unaffected either way --
# those keys take precedence and never go near the database.
if grep -qE '^[[:space:]]*RELAY_KEY=.+' .env; then
    echo "✅ RELAY_KEY present"
elif grep -qE '^[[:space:]]*RELAY_KEY=[[:space:]]*$' .env; then
    echo "❌ RELAY_KEY is present but empty in .env."
    echo "   Set a value (or delete the empty line and re-run this script):"
    echo "     echo \"RELAY_KEY=\$(openssl rand -base64 32)\" >> .env"
    exit 1
else
    printf '\n# Encrypts the outbound relay password in the database (added by update.sh).\n# Changing it means re-entering the credentials in Settings -> Sending.\nRELAY_KEY=%s\n' \
        "$(openssl rand -base64 32)" >> .env
    echo "✅ added RELAY_KEY to .env"
fi

# VAPID became required with Phase 6 (push notifications). Same shape again.
# Safe to generate here: the keys only mean anything to push subscriptions,
# and an install that has never had the feature has no subscriptions to
# invalidate. A P-256 keypair as base64url -- the private key is the 32-byte
# scalar, the public key the uncompressed point -- which is what
# `web-push generate-vapid-keys` emits and what openssl can produce without
# Node being installed on the server.
if grep -qE '^[[:space:]]*VAPID_PUBLIC_KEY=.+' .env && \
   grep -qE '^[[:space:]]*VAPID_PRIVATE_KEY=.+' .env; then
    echo "✅ VAPID keys present"
elif grep -qE '^[[:space:]]*VAPID_(PUBLIC|PRIVATE)_KEY=[[:space:]]*$' .env; then
    echo "❌ VAPID_PUBLIC_KEY / VAPID_PRIVATE_KEY are present but empty in .env."
    echo "   Delete the empty lines and re-run this script, or set a pair with:"
    echo "     npx web-push generate-vapid-keys"
    exit 1
else
    UPD_VAPID_PEM=$(mktemp)
    openssl ecparam -name prime256v1 -genkey -noout -out "$UPD_VAPID_PEM" 2>/dev/null
    printf '\n# Web Push VAPID keypair (added by update.sh)\nVAPID_PUBLIC_KEY=%s\nVAPID_PRIVATE_KEY=%s\n' \
        "$(openssl ec -in "$UPD_VAPID_PEM" -pubout -outform DER 2>/dev/null \
            | tail -c 65 | base64 | tr '+/' '-_' | tr -d '=\n')" \
        "$(openssl ec -in "$UPD_VAPID_PEM" -outform DER 2>/dev/null \
            | tail -c +8 | head -c 32 | base64 | tr '+/' '-_' | tr -d '=\n')" >> .env
    rm -f "$UPD_VAPID_PEM"
    echo "✅ added VAPID_PUBLIC_KEY / VAPID_PRIVATE_KEY to .env"
fi

# The one MAIL_SUBDOMAIN became two.
#
# It was the *web* hostname all along -- Nginx's server_name and the certificate
# -- while Postfix's $myhostname was hardcoded to `mail.$DOMAIN` and could not
# be changed at all. One variable whose name said "mail" and whose value meant
# "web", next to a mail hostname that was not a variable. So:
#
#   WEB_SUBDOMAIN   what MAIL_SUBDOMAIN always meant. Same value, honest name.
#   SMTP_SUBDOMAIN  what was hardcoded. Defaulted to `mail` here, which is what
#                   it has been on every existing install -- so this migration
#                   changes no behaviour and needs no DNS change.
#
# MAIL_SUBDOMAIN is left in .env untouched. Nothing reads it while
# WEB_SUBDOMAIN is set, and rewriting a line the customer may have edited is
# not worth the risk of getting it wrong.
if grep -qE '^[[:space:]]*WEB_SUBDOMAIN=.+' .env; then
    echo "✅ WEB_SUBDOMAIN present"
else
    OLD_WEB=$(grep -E '^[[:space:]]*MAIL_SUBDOMAIN=.+' .env | head -1 | cut -d= -f2- | tr -d '"'"'"' ' || true)
    OLD_WEB="${OLD_WEB:-webmail}"
    printf '\n# The webmail hostname, renamed from MAIL_SUBDOMAIN by update.sh.\nWEB_SUBDOMAIN=%s\n' \
        "$OLD_WEB" >> .env
    echo "✅ added WEB_SUBDOMAIN=$OLD_WEB to .env (was MAIL_SUBDOMAIN)"
fi

if grep -qE '^[[:space:]]*SMTP_SUBDOMAIN=.+' .env; then
    echo "✅ SMTP_SUBDOMAIN present"
else
    printf '\n# The mail server hostname -- MX target, HELO name, PTR record.\n# Was hardcoded to `mail` before it became a setting; do not change it on an\n# install that is already delivering without moving MX, PTR and SPF with it.\nSMTP_SUBDOMAIN=mail\n' >> .env
    echo "✅ added SMTP_SUBDOMAIN=mail to .env (the previous hardcoded value)"
fi

# DKIM keys moved out of the rspamd_data volume and into ./dkim.
#
# They used to be generated by `rspamadm dkim_keygen` inside the rspamd
# container, into /var/lib/rspamd/dkim -- a path inside a named volume that no
# other container could see. Settings -> Domains needs the *web* container to
# be able to write a key when an admin adds a second mail domain, so the
# directory is now a host bind mount shared by both.
#
# The new compose file mounts ./dkim over /var/lib/rspamd/dkim, which would
# hide whatever is in the volume. So copy it out first, while the old container
# is still running with the old mounts. Docker's own `cp` is used rather than
# `docker compose cp`, so this does not depend on the compose file that has
# already been replaced by the git pull above.
mkdir -p dkim
if [ -z "$(ls -A dkim 2>/dev/null | grep -v '^\.gitkeep$')" ] \
   && docker ps --format '{{.Names}}' | grep -qx una-rspamd; then
    if docker cp una-rspamd:/var/lib/rspamd/dkim/. ./dkim/ 2>/dev/null; then
        # Only the private keys are secret; the rest of the directory listing
        # is public material. Re-apply the modes the new code expects, and the
        # group Rspamd reads as (uid/gid 11333 in rspamd/rspamd:4.1) -- a
        # root:root 0640 key on this bind mount is one Rspamd cannot open, and
        # the symptom is mail going out unsigned with nothing in the log.
        chmod 755 dkim
        find dkim -name '*.key' -exec chmod 640 {} \; 2>/dev/null || true
        find dkim -name '*.key' -exec chgrp 11333 {} \; 2>/dev/null || true
        find dkim \( -name '*.pub' -o -name '*.dns.txt' \) -exec chmod 644 {} \; 2>/dev/null || true
        if ls dkim/*.key >/dev/null 2>&1; then
            echo "✅ moved DKIM keys out of the rspamd volume into ./dkim"
        else
            echo "✅ ./dkim ready (no keys were in the rspamd volume)"
        fi
    else
        echo "⚠️  Could not copy DKIM keys out of the rspamd container."
        echo "   If mail stops being DKIM-signed after this update, run:"
        echo "     docker cp una-rspamd:/var/lib/rspamd/dkim/. ./dkim/"
        echo "   then ./update.sh again."
    fi
else
    echo "✅ ./dkim present"
fi

# The Rspamd config moved out of this repo and into the rspamd image.
#
# ./rspamd/local.d used to be bind-mounted over /etc/rspamd/local.d. The pull
# above deleted the tracked files in it and compose no longer mounts it, so an
# install that never touched them needs nothing and this is silent. A directory
# still standing here after the pull means untracked files -- somebody's own map
# or .conf -- which are now being ignored rather than applied, and the only
# honest thing to do is say so rather than let a customisation quietly lapse.
mkdir -p rspamd/override.d
if [ -d rspamd/local.d ] && [ -n "$(ls -A rspamd/local.d 2>/dev/null)" ]; then
    echo "⚠️  rspamd/local.d still has files, and nothing reads them any more."
    echo ""
    echo "   UNA's Rspamd config ships inside the rspamd image now. These look"
    echo "   like your own additions:"
    ( cd rspamd/local.d && find . -type f | sed 's|^\./|     |' )
    echo ""
    echo "   Move anything you still want into rspamd/override.d/, which is"
    echo "   mounted and is not tracked by git, then delete rspamd/local.d."
    echo "   Note override.d *replaces* a section where local.d merged into it,"
    echo "   so each file must restate the whole block it overrides."
    echo ""
elif [ -d rspamd/local.d ]; then
    rmdir rspamd/local.d 2>/dev/null || true
fi

# Same move for Nginx: its template and entrypoint are in the nginx image now.
if [ -d nginx ] && [ -z "$(ls -A nginx 2>/dev/null)" ]; then
    rmdir nginx 2>/dev/null || true
fi

# Load configuration only after .env is known to be complete.
set -a
# shellcheck disable=SC1091
. ./.env
set +a

# Re-read after the migration above wrote them, with the same fallbacks the
# compose file uses so this prints what the containers will actually see.
SMTP_SUBDOMAIN="${SMTP_SUBDOMAIN:-mail}"
WEB_SUBDOMAIN="${WEB_SUBDOMAIN:-${MAIL_SUBDOMAIN:-webmail}}"
echo "Domain: $DOMAIN"
echo "Mail server: $SMTP_SUBDOMAIN.$DOMAIN  (MX, HELO, PTR)"
echo "Web interface: $WEB_SUBDOMAIN.$DOMAIN"
echo ""

# Validate the compose file before we touch anything.
if ! docker compose config --quiet 2>/dev/null; then
    echo "❌ Could not read docker-compose.yml. Output:"
    docker compose config --quiet || true
    exit 1
fi

# ============================================
# Step 3: Create Backup
# ============================================
echo "Step 3: Creating Backup"
echo "-----------------------"

# The dump is not a courtesy copy -- it is this script's rollback. If the
# migration in step 7 fails, step 7 restores from it and puts you back where
# you started. Skipping is allowed, because on a large mailbox it is the
# slowest part of an update and an operator with their own snapshots does not
# need a second one, but skipping means a failed migration stops and waits for
# a human instead of undoing itself. So: asked, not assumed, and the default is
# yes.
#
# UNA_BACKUP=0 (or no/false) skips without asking, 1 (or yes/true) takes it
# without asking -- for cron and for anyone scripting this. A command-line
# assignment survives the re-exec at the top of this script, because it is in
# the environment rather than in "$@".
#
# When nothing is on a terminal -- piped, or run from a job -- `read` sees EOF
# and returns non-zero, which under this script's `set -e` would end the update
# right here without printing a thing. `|| BACKUP_CHOICE=""` swallows that, and
# an empty answer is the default: an unattended update backs up.
BACKUP_WANTED="ask"
case "$(printf '%s' "${UNA_BACKUP:-}" | tr '[:upper:]' '[:lower:]')" in
    0|no|false) BACKUP_WANTED="no" ;;
    1|yes|true) BACKUP_WANTED="yes" ;;
    "") ;;
    *)
        echo "❌ UNA_BACKUP must be 0/no/false or 1/yes/true (got '$UNA_BACKUP')."
        exit 1
        ;;
esac

if [ "$BACKUP_WANTED" = "ask" ]; then
    echo "A backup is what this script restores from if the database migration"
    echo "fails. Without one, a failed migration leaves the update stopped"
    echo "part-way and needs fixing by hand."
    echo ""
    BACKUP_CHOICE=""
    read -p "Back up the database first? (Y/n): " BACKUP_CHOICE || BACKUP_CHOICE=""
    case "$BACKUP_CHOICE" in
        n|N|no|NO|No) BACKUP_WANTED="no" ;;
        *) BACKUP_WANTED="yes" ;;
    esac
    echo ""
fi

BACKUP_FILE=""

if [ "$BACKUP_WANTED" = "no" ]; then
    echo "⏭️  Skipping backup — a failed migration will not roll back on its own."
else
    BACKUP_DIR="backups"
    mkdir -p "$BACKUP_DIR"

    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    BACKUP_FILE="$BACKUP_DIR/backup_${TIMESTAMP}.sql"

    echo "📦 Backing up database..."
    if docker compose exec -T postgres pg_dump -U una_email una_email > "$BACKUP_FILE" 2>/dev/null; then
        BACKUP_SIZE=$(ls -lh "$BACKUP_FILE" | awk '{print $5}')
        echo "✅ Backup saved: $BACKUP_FILE ($BACKUP_SIZE)"
    else
        echo "⚠️  Could not create backup (database may not be running)"
        echo ""
        # Same EOF-under-`set -e` care as above; here an empty answer means
        # cancel, so an unattended update stops rather than pressing on
        # without the rollback it expected to have.
        CONTINUE=""
        read -p "Continue without backup? (y/N): " CONTINUE || CONTINUE=""
        if [ "$CONTINUE" != "y" ] && [ "$CONTINUE" != "Y" ]; then
            echo "Update cancelled."
            exit 1
        fi
        rm -f "$BACKUP_FILE"
        BACKUP_FILE=""
    fi
fi
echo ""

# ============================================
# Step 4: Pull New Images
# ============================================
echo "Step 4: Pulling Latest Images"
echo "-----------------------------"

# IMAGE_TAG pinned to a release from before rspamd and nginx were published as
# images will not find them: CI only started tagging those two from this
# version on, and `docker compose pull` fails on a manifest that does not
# exist. Caught here so the message names the setting instead of a registry
# 404. Everyone on the default `latest` sails past this.
if [ -n "${IMAGE_TAG:-}" ] && [ "$IMAGE_TAG" != "latest" ]; then
    if ! docker manifest inspect \
        "ghcr.io/${GITHUB_REPOSITORY:-roncanfil/una.email}/rspamd:${IMAGE_TAG}" \
        > /dev/null 2>&1; then
        echo "❌ No rspamd image published at IMAGE_TAG=$IMAGE_TAG."
        echo ""
        echo "   Rspamd and Nginx are published images as of this release; tags"
        echo "   older than it only cover web and mail. Set IMAGE_TAG=latest in"
        echo "   .env (or pin a tag from this release onwards) and re-run."
        exit 1
    fi
fi

echo "🚀 Downloading updates..."
docker compose pull

echo "✅ Images updated"
echo ""

# ============================================
# Step 5: Restart Services
# ============================================
echo "Step 5: Restarting Services"
echo "---------------------------"

echo "🛑 Stopping containers..."
docker compose down

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
    docker compose logs --tail 40 postgres
    exit 1
fi

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
    echo "⚠️  Web container not responding yet; attempting migrations anyway."
fi

echo "📋 Service status:"
docker compose ps --format "table {{.Name}}\t{{.Status}}"
echo ""

# ============================================
# Step 6: Run Migrations
# ============================================
echo "Step 6: Database Migrations"
echo "---------------------------"

# Every box installed before February 2026 was built by `prisma db push`, so
# it has the schema and an empty _prisma_migrations. `migrate deploy` refuses
# those with P3005, "The database schema is not empty" -- which is why this
# step has never actually succeeded on such a box. The helper records the
# migrations the database already has so that deploy can apply the rest. It
# does nothing on a database that already has migration rows.
#
# The helper ships inside the web image, so an image built before it existed
# will not have it. That is not fatal: the migrate deploy below then fails the
# way it already does today, and the rollback path takes over.
echo "🧾 Recording any migrations this database already has..."
if docker compose exec -T web test -f scripts/baseline-migrations.js 2>/dev/null; then
    if ! docker compose exec -T web node scripts/baseline-migrations.js; then
        echo "⚠️  Could not record the existing migration history."
        echo "   The migration step below will report what went wrong."
    fi
else
    echo "⚠️  This web image predates the baseline helper; skipping."
    echo "   If migrations fail with P3005, re-run update.sh once a newer"
    echo "   image has been pulled."
fi
echo ""

echo "🗄️  Applying database migrations..."
if docker compose exec -T web npx prisma migrate deploy 2>&1; then
    echo "✅ Migrations complete"
else
    echo ""
    echo "❌ Migration failed!"
    echo ""

    if [ -n "$BACKUP_FILE" ]; then
        echo "🔄 Rolling back..."
        docker compose down
        # Brings up the same PostgreSQL the backup was just taken from.
        docker compose up -d postgres
        for _ in $(seq 1 60); do
            docker compose exec -T postgres pg_isready -U una_email > /dev/null 2>&1 && break
            sleep 1
        done
        # ON_ERROR_STOP: without it psql skips what it cannot apply and still
        # exits 0, so a rollback that only half worked would announce itself as
        # a success. A plain pg_dump has no DROPs of its own either, which is
        # why the database is recreated rather than restored over.
        docker compose exec -T postgres psql -U una_email -d postgres -v ON_ERROR_STOP=1 \
            -c "DROP DATABASE IF EXISTS una_email WITH (FORCE)" \
            -c "CREATE DATABASE una_email OWNER una_email" > /dev/null
        docker compose exec -T postgres psql -U una_email una_email -v ON_ERROR_STOP=1 < "$BACKUP_FILE"
        docker compose up -d
        echo ""
        echo "✅ Rolled back to previous state"
        echo "   Your data has been restored from: $BACKUP_FILE"
    else
        echo "⚠️  No backup was taken, so nothing was rolled back."
        echo "   The database is part-way through a migration and the new"
        echo "   images are already pulled. If you have a dump of your own:"
        echo ""
        echo "     ./restore.sh your-dump.sql"
    fi

    echo ""
    echo "Please contact support@una.email with the error above."
    exit 1
fi
echo ""

# ============================================
# Step 7: Health Check
# ============================================
echo "Step 7: Verification"
echo "--------------------"

# Check web interface
echo -n "🌐 Web interface: "
sleep 5
if docker compose exec -T web wget -q -O /dev/null http://localhost:3000 > /dev/null 2>&1; then
    echo "✅ Responding"
else
    echo "⚠️  Not responding (may still be starting)"
fi

# Check Postfix
echo -n "📧 Mail server: "
if docker compose exec -T postfix postfix status > /dev/null 2>&1; then
    echo "✅ Running"
else
    echo "⚠️  Check logs: docker compose logs postfix"
fi

# Check Rspamd
echo -n "🛡️  Spam filter: "
if docker compose exec -T rspamd rspamadm configtest > /dev/null 2>&1; then
    echo "✅ Running"
else
    echo "⚠️  Check logs: docker compose logs rspamd"
fi

# Rspamd must actually be adding the headers the web app reads. An empty
# `use` list means milter_headers never loaded, and it stores every inbound
# message with a NULL spam score.
echo -n "🏷️  Spam headers: "
if docker compose exec -T rspamd rspamadm configdump milter_headers 2>/dev/null \
    | grep -q 'x-spamd-result'; then
    echo "✅ Configured"
else
    echo "⚠️  milter_headers is empty — inbound mail will have no spam score."
    echo "     The rspamd image ships this config, so an empty list means the"
    echo "     image is stale or an override.d file replaced it. Check:"
    echo "       docker compose exec rspamd rspamadm configdump milter_headers"
    echo "       ls rspamd/override.d/"
fi

# The controller owns /learnspam and /learnham. If it still accepts the image
# default "q1", reporting spam is an unauthenticated endpoint.
echo -n "🔑 Rspamd controller: "
# Asked from the postfix container, not the rspamd one: the rspamd image ships
# neither curl nor wget. postfix has curl and sits on the same compose network.
RSPAMD_CODE=$(docker compose exec -T postfix \
    curl -s -o /dev/null -w '%{http_code}' -H "Password: q1" \
    http://rspamd:11334/stat 2>/dev/null || echo "000")
if [ "$RSPAMD_CODE" = "401" ]; then
    echo "✅ Password protected (default 'q1' rejected)"
elif [ "$RSPAMD_CODE" = "200" ]; then
    echo "❌ Still accepting the default password 'q1'!"
    echo "     RSPAMD_PASSWORD is not reaching the container."
    echo "     Check .env and: docker compose up -d rspamd"
else
    echo "⚠️  Could not reach the controller (HTTP $RSPAMD_CODE)"
fi

echo ""

# ============================================
# Complete
# ============================================
echo "=========================================="
echo "       Update Complete!"
echo "=========================================="
echo ""

if [ -n "$BACKUP_FILE" ]; then
    echo "📦 Backup saved to: $BACKUP_FILE"
    echo "   (Delete after verifying everything works)"
    echo ""
fi

echo "🌐 Web Interface: https://$WEB_SUBDOMAIN.$DOMAIN"
echo ""
echo "📋 Useful commands:"
echo "   docker compose logs -f       # View all logs"
echo "   docker compose ps            # Check service status"
echo ""
