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
            | tail -c 65 | base64 | tr '+/' '-_' | tr -d '=')" \
        "$(openssl ec -in "$UPD_VAPID_PEM" -outform DER 2>/dev/null \
            | tail -c +8 | head -c 32 | base64 | tr '+/' '-_' | tr -d '=')" >> .env
    rm -f "$UPD_VAPID_PEM"
    echo "✅ added VAPID_PUBLIC_KEY / VAPID_PRIVATE_KEY to .env"
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

MAIL_SUBDOMAIN="${MAIL_SUBDOMAIN:-mail}"
echo "Domain: $DOMAIN"
echo "Mail subdomain: $MAIL_SUBDOMAIN"
echo ""

# Compose normalises the project name, so ask Compose rather than guessing at
# the directory name. This also validates the compose file before we touch
# anything.
# `| head -1` is deliberately NOT used here: under `set -o pipefail` head exits
# after the first line, sed is killed by SIGPIPE, and the whole pipeline reports
# 141 -- which aborts this script under `set -e` before it prints anything at
# all. It races, so it looks fine on macOS and fails on Linux, which is every
# server this runs on. Let sed stop by itself instead.
PROJECT="$(docker compose config --format json 2>/dev/null \
    | sed -n '/"name":/{s/.*"name": *"\([^"]*\)".*/\1/p;q;}')"
if [ -z "$PROJECT" ]; then
    echo "❌ Could not read docker-compose.yml. Output:"
    docker compose config --quiet || true
    exit 1
fi

# ============================================
# Step 3: PostgreSQL Major Version
# ============================================
echo "Step 3: PostgreSQL Version"
echo "--------------------------"

# PostgreSQL 18 has no in-place upgrade from 15, and the official 18 image
# mounts a different path (/var/lib/postgresql, PGDATA /var/lib/postgresql/18/
# docker) than 15 did. So the data moves to a new volume via dump/restore, and
# it has to happen BEFORE the new compose file starts an 18 server.
#
# Detect from the volumes, not from the running container: at this point the
# stack may be down, and the compose file on disk already says 18.
OLD_VOL="${PROJECT}_postgres_data"
NEW_VOL="${PROJECT}_postgres_data_18"

OLD_PG_VERSION=""
if docker volume inspect "$OLD_VOL" > /dev/null 2>&1; then
    OLD_PG_VERSION=$(docker run --rm -v "$OLD_VOL":/old:ro alpine \
        cat /old/PG_VERSION 2>/dev/null | tr -d '[:space:]')
fi

NEW_PG_VERSION=""
if docker volume inspect "$NEW_VOL" > /dev/null 2>&1; then
    NEW_PG_VERSION=$(docker run --rm -v "$NEW_VOL":/new:ro alpine \
        cat /new/18/docker/PG_VERSION 2>/dev/null | tr -d '[:space:]')
fi

if [ -n "$NEW_PG_VERSION" ]; then
    echo "✅ Already on PostgreSQL $NEW_PG_VERSION"
elif [ -z "$OLD_PG_VERSION" ]; then
    echo "✅ No existing PostgreSQL data — nothing to upgrade"
elif [ "$OLD_PG_VERSION" = "15" ]; then
    echo "⚠️  Your data is on PostgreSQL 15. This release runs PostgreSQL 18."
    echo ""

    # The upgrade script dumps from the RUNNING 15 container. It does not write
    # to the 15 volume at any point, so this is safe to retry.
    if ! docker ps --format '{{.Names}}' | grep -qx "una-postgres"; then
        echo "❌ The PostgreSQL 15 container is not running, and the compose file"
        echo "   in this checkout now describes PostgreSQL 18 — starting it would"
        echo "   not give us the 15 server the upgrade needs to dump from."
        echo ""
        echo "   Start your old stack, then run this script again:"
        echo ""
        echo "     git stash                       # keep the new files for later"
        echo "     git checkout 3246e1d            # the last PostgreSQL 15 release"
        echo "     docker compose up -d postgres"
        echo "     git checkout main && git stash pop"
        echo "     ./update.sh"
        echo ""
        echo "   Your data is untouched."
        exit 1
    fi

    echo "🐘 Upgrading PostgreSQL 15 → 18 (dump and restore onto a new volume)."
    echo "   Your PostgreSQL 15 volume is not written to and stays available"
    echo "   for rollback."
    echo ""
    if ! ./scripts/upgrade-postgres.sh; then
        echo ""
        echo "❌ The PostgreSQL 15 → 18 upgrade failed."
        echo ""
        echo "   Your PostgreSQL 15 volume was never written to, so your data is"
        echo "   intact and you can stay on 15: check out the previous"
        echo "   install-repo commit and bring the old stack back up with"
        echo "     git checkout 3246e1d && docker compose up -d"
        echo "   then send the error above to support@una.email."
        exit 1
    fi
    echo "✅ PostgreSQL upgraded to 18"
else
    echo "❌ Unexpected PostgreSQL version on '$OLD_VOL': $OLD_PG_VERSION"
    echo "   Expected 15 (or an already-migrated 18 volume)."
    echo "   Contact support@una.email before continuing."
    exit 1
fi
echo ""

# ============================================
# Step 4: Create Backup
# ============================================
echo "Step 4: Creating Backup"
echo "-----------------------"

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
    read -p "Continue without backup? (y/N): " CONTINUE
    if [ "$CONTINUE" != "y" ] && [ "$CONTINUE" != "Y" ]; then
        echo "Update cancelled."
        exit 1
    fi
    rm -f "$BACKUP_FILE"
    BACKUP_FILE=""
fi
echo ""

# ============================================
# Step 5: Pull New Images
# ============================================
echo "Step 5: Pulling Latest Images"
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
# Step 6: Restart Services
# ============================================
echo "Step 6: Restarting Services"
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
# Step 7: Run Migrations
# ============================================
echo "Step 7: Database Migrations"
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
        # Brings up PostgreSQL 18 on postgres_data_18 -- the same server the
        # backup was just taken from. The dump is logical, so it restores onto
        # 18 regardless of which major it came from.
        docker compose up -d postgres
        for _ in $(seq 1 60); do
            docker compose exec -T postgres pg_isready -U una_email > /dev/null 2>&1 && break
            sleep 1
        done
        docker compose exec -T postgres psql -U una_email una_email < "$BACKUP_FILE"
        docker compose up -d
        echo ""
        echo "✅ Rolled back to previous state"
        echo "   Your data has been restored from: $BACKUP_FILE"
    fi

    echo ""
    echo "Please contact support@una.email with the error above."
    exit 1
fi
echo ""

# ============================================
# Step 8: Health Check
# ============================================
echo "Step 8: Verification"
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

if [ -n "$OLD_PG_VERSION" ] && [ "$OLD_PG_VERSION" = "15" ]; then
    echo "🐘 Your PostgreSQL 15 data volume ('$OLD_VOL') was left in place."
    echo "   Once you are happy with this release, reclaim the space:"
    echo "     docker volume rm $OLD_VOL"
    echo ""
fi

echo "🌐 Web Interface: https://$MAIL_SUBDOMAIN.$DOMAIN"
echo ""
echo "📋 Useful commands:"
echo "   docker compose logs -f       # View all logs"
echo "   docker compose ps            # Check service status"
echo ""
