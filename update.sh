#!/bin/bash

# UNA.Email Update Script
# Safely updates UNA Email with automatic backup and rollback

set -e

# shellcheck source=lib/ui.sh
. "$(dirname "$0")/lib/ui.sh"

# Once, not again when the script re-execs itself after the pull below.
if [ -z "${UNA_UPDATE_REEXEC:-}" ]; then
    ui_banner "Update"
fi

# Check if installed
if [ ! -f .env ]; then
    ui_fail "No .env file found."
    ui_note "Is UNA Email installed in this directory?"
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
    ui_step 1 7 "Updating UNA Email files"

    if [ ! -d .git ]; then
        ui_fail "This directory is not a git checkout."
        ui_note "update.sh needs to pull the latest compose file and scripts,"
        ui_note "not just the container images. Re-install from git:"
        ui_cmd "git clone https://github.com/roncanfil/una.email-install.git"
        ui_note "and copy your existing .env into the new checkout."
        exit 1
    fi

    SELF_BEFORE=$(git rev-parse HEAD:update.sh 2>/dev/null || echo none)

    # In the open rather than behind a spinner: if git has to ask for
    # anything -- a host key, a credential -- the question must be visible.
    ui_run "Pulling the latest UNA Email files..."
    if git pull --ff-only --quiet; then
        ui_ok "Files updated"
    else
        ui_fail "git pull failed."
        ui_note "If you have local edits to tracked files, stash or revert them:"
        ui_cmd "git stash            # keep them"
        ui_cmd "git checkout -- .    # discard them"
        ui_note "then run ./update.sh again. Your .env is not tracked and is safe."
        exit 1
    fi

    SELF_AFTER=$(git rev-parse HEAD:update.sh 2>/dev/null || echo none)
    if [ "$SELF_BEFORE" != "$SELF_AFTER" ]; then
        ui_info "update.sh itself changed. Restarting with the new version."
        export UNA_UPDATE_REEXEC=1
        exec bash "$0" "$@"
    fi
fi

# ============================================
# Step 2: Check Configuration
# ============================================
ui_step 2 7 "Configuration"

# RSPAMD_PASSWORD became required: docker-compose.yml refuses to start without
# it. Installs made before it existed have no such line, so add one. Only ever
# append -- never rewrite DOMAIN, DB_PASSWORD or anything else the customer set.
if grep -qE '^[[:space:]]*RSPAMD_PASSWORD=.+' .env; then
    ui_ok "RSPAMD_PASSWORD present"
elif grep -qE '^[[:space:]]*RSPAMD_PASSWORD=[[:space:]]*$' .env; then
    ui_fail "RSPAMD_PASSWORD is present but empty in .env."
    ui_note "Set a value (or delete the empty line and re-run this script):"
    ui_cmd "echo \"RSPAMD_PASSWORD=\$(openssl rand -base64 24)\" >> .env"
    exit 1
else
    printf '\n# Rspamd controller password (added by update.sh)\nRSPAMD_PASSWORD=%s\n' \
        "$(openssl rand -base64 24)" >> .env
    ui_ok "Added RSPAMD_PASSWORD to .env"
fi

# SESSION_SECRET became required with Phase 5 (sign-in). Same shape as above:
# compose refuses to start without it, and an install made before sign-in
# existed has no such line. Generating one here is safe -- there are no
# sessions to invalidate on an install that has never had any.
if grep -qE '^[[:space:]]*SESSION_SECRET=.+' .env; then
    ui_ok "SESSION_SECRET present"
elif grep -qE '^[[:space:]]*SESSION_SECRET=[[:space:]]*$' .env; then
    ui_fail "SESSION_SECRET is present but empty in .env."
    ui_note "Set a value (or delete the empty line and re-run this script):"
    ui_cmd "echo \"SESSION_SECRET=\$(openssl rand -base64 32)\" >> .env"
    exit 1
else
    printf '\n# Session signing secret (added by update.sh)\nSESSION_SECRET=%s\n' \
        "$(openssl rand -base64 32)" >> .env
    ui_ok "Added SESSION_SECRET to .env"
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
    ui_ok "RELAY_KEY present"
elif grep -qE '^[[:space:]]*RELAY_KEY=[[:space:]]*$' .env; then
    ui_fail "RELAY_KEY is present but empty in .env."
    ui_note "Set a value (or delete the empty line and re-run this script):"
    ui_cmd "echo \"RELAY_KEY=\$(openssl rand -base64 32)\" >> .env"
    exit 1
else
    printf '\n# Encrypts the outbound relay password in the database (added by update.sh).\n# Changing it means re-entering the credentials in Settings -> Sending.\nRELAY_KEY=%s\n' \
        "$(openssl rand -base64 32)" >> .env
    ui_ok "Added RELAY_KEY to .env"
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
    ui_ok "VAPID keys present"
elif grep -qE '^[[:space:]]*VAPID_(PUBLIC|PRIVATE)_KEY=[[:space:]]*$' .env; then
    ui_fail "VAPID_PUBLIC_KEY / VAPID_PRIVATE_KEY are present but empty in .env."
    ui_note "Delete the empty lines and re-run this script, or set a pair with:"
    ui_cmd "npx web-push generate-vapid-keys"
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
    ui_ok "Added VAPID_PUBLIC_KEY / VAPID_PRIVATE_KEY to .env"
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
    ui_ok "WEB_SUBDOMAIN present"
else
    OLD_WEB=$(grep -E '^[[:space:]]*MAIL_SUBDOMAIN=.+' .env | head -1 | cut -d= -f2- | tr -d '"'"'"' ' || true)
    OLD_WEB="${OLD_WEB:-webmail}"
    printf '\n# The webmail hostname, renamed from MAIL_SUBDOMAIN by update.sh.\nWEB_SUBDOMAIN=%s\n' \
        "$OLD_WEB" >> .env
    ui_ok "Added WEB_SUBDOMAIN=$OLD_WEB to .env (was MAIL_SUBDOMAIN)"
fi

if grep -qE '^[[:space:]]*SMTP_SUBDOMAIN=.+' .env; then
    ui_ok "SMTP_SUBDOMAIN present"
else
    printf '\n# The mail server hostname -- MX target, HELO name, PTR record.\n# Was hardcoded to `mail` before it became a setting; do not change it on an\n# install that is already delivering without moving MX, PTR and SPF with it.\nSMTP_SUBDOMAIN=mail\n' >> .env
    ui_ok "Added SMTP_SUBDOMAIN=mail to .env (the previous hardcoded value)"
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
            ui_ok "Moved DKIM keys out of the rspamd volume into ./dkim"
        else
            ui_ok "./dkim ready (no keys were in the rspamd volume)"
        fi
    else
        ui_warn "Could not copy DKIM keys out of the rspamd container."
        ui_note "If mail stops being DKIM-signed after this update, run:"
        ui_cmd "docker cp una-rspamd:/var/lib/rspamd/dkim/. ./dkim/"
        ui_note "then ./update.sh again."
    fi
else
    ui_ok "./dkim present"
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
    ui_warn "rspamd/local.d still has files, and nothing reads them any more."
    ui_note "UNA's Rspamd config ships inside the rspamd image now. These look"
    ui_note "like your own additions:"
    ( cd rspamd/local.d && find . -type f | sed 's|^\./|  |' ) | ui_indent
    ui_note "Move anything you still want into rspamd/override.d/, which is"
    ui_note "mounted and is not tracked by git, then delete rspamd/local.d."
    ui_note "Note override.d *replaces* a section where local.d merged into it,"
    ui_note "so each file must restate the whole block it overrides."
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
echo ""
ui_kv "Domain" "$DOMAIN"
ui_kv "Mail server" "$SMTP_SUBDOMAIN.$DOMAIN  (MX, HELO, PTR)"
ui_kv "Web interface" "$WEB_SUBDOMAIN.$DOMAIN"
echo ""

# Validate the compose file before we touch anything.
if ! docker compose config --quiet 2>/dev/null; then
    ui_fail "Could not read docker-compose.yml. Output:"
    docker compose config --quiet 2>&1 | ui_indent || true
    exit 1
fi

# Prove DB_PASSWORD still opens the database before anything is stopped.
#
# Postgres keeps the password its volume was first initialised with and never
# reads DB_PASSWORD again. .env can drift from it, and running containers keep
# the environment they were started with, so the drift stays invisible until
# the containers are recreated -- which is exactly what step 5 does. Found
# there, it means downtime and a migration that cannot connect; found here, it
# means nothing has been touched yet.
DB_PASSWORD_EFFECTIVE="${DB_PASSWORD:-una_email_password}"

# The compose file splices the password into a postgresql:// URL unencoded, so
# these characters break the URL even when the password itself is right.
if printf '%s' "$DB_PASSWORD_EFFECTIVE" | grep -qE '[][@:/?#%[:space:]]'; then
    ui_fail "DB_PASSWORD contains a character that breaks the database URL"
    ui_note "(one of @ : / ? # % [ ] or a space)."
    ui_note
    ui_note "Pick a password of letters and digits (openssl rand -hex 16 makes"
    ui_note "one), put it in .env as DB_PASSWORD, set the database to match:"
    ui_note
    ui_cmd "echo \"ALTER ROLE una_email WITH PASSWORD :'pw';\" | \\"
    ui_cmd "  docker compose exec -T postgres psql -U una_email -d una_email \\"
    ui_cmd "  -v pw=\"\$(grep '^DB_PASSWORD=' .env | cut -d= -f2-)\""
    ui_note
    ui_note "then run ./update.sh again. Nothing has been changed."
    exit 1
fi

# The fix above goes in on stdin because psql does not substitute :'pw' in a
# -c string, and -v keeps the password out of the SQL text.
#
# Over the network (-h postgres), the way the app connects. The image trusts
# the socket and localhost, so a check through either passes with any password.
if docker compose ps --status running --services 2>/dev/null | grep -qx postgres; then
    if docker compose exec -T -e PGPASSWORD="$DB_PASSWORD_EFFECTIVE" postgres \
        psql -h postgres -U una_email -d una_email -tAc 'select 1' > /dev/null 2>&1; then
        ui_ok "DB_PASSWORD opens the database"
    else
        ui_fail "The database does not accept the DB_PASSWORD in .env."
        ui_note "Postgres still has the password it was first set up with. If the"
        ui_note "one in .env is the one you want, set the database to match it:"
        ui_note
        ui_cmd "echo \"ALTER ROLE una_email WITH PASSWORD :'pw';\" | \\"
        ui_cmd "  docker compose exec -T postgres psql -U una_email -d una_email \\"
        ui_cmd "  -v pw=\"\$(grep '^DB_PASSWORD=' .env | cut -d= -f2-)\""
        ui_note
        ui_note "then run ./update.sh again. Nothing has been changed."
        exit 1
    fi
else
    ui_warn "Postgres is not running, so DB_PASSWORD could not be checked."
fi

# ============================================
# Step 3: Create Backup
# ============================================
ui_step 3 7 "Backup"

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
        ui_fail "UNA_BACKUP must be 0/no/false or 1/yes/true (got '$UNA_BACKUP')."
        exit 1
        ;;
esac

if [ "$BACKUP_WANTED" = "ask" ]; then
    ui_text "A backup is what this script restores from if the database migration"
    ui_text "fails. Without one, a failed migration leaves the update stopped"
    ui_text "part-way and needs fixing by hand."
    echo ""
    BACKUP_CHOICE=""
    ui_ask BACKUP_CHOICE "Back up the database first?" "Y/n" || BACKUP_CHOICE=""
    case "$BACKUP_CHOICE" in
        n|N|no|NO|No) BACKUP_WANTED="no" ;;
        *) BACKUP_WANTED="yes" ;;
    esac
fi

BACKUP_FILE=""

if [ "$BACKUP_WANTED" = "no" ]; then
    ui_info "Skipping backup. A failed migration will not roll back on its own."
else
    BACKUP_DIR="backups"
    mkdir -p "$BACKUP_DIR"

    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    BACKUP_FILE="$BACKUP_DIR/backup_${TIMESTAMP}.sql"

    dump_database() {
        docker compose exec -T postgres pg_dump -U una_email una_email > "$BACKUP_FILE" 2>/dev/null
    }
    if ui_spin "Backing up the database" "" dump_database; then
        BACKUP_SIZE=$(ls -lh "$BACKUP_FILE" | awk '{print $5}')
        ui_ok "Backup saved: $BACKUP_FILE ($BACKUP_SIZE)"
    else
        ui_warn "Could not create a backup (the database may not be running)."
        # Same EOF-under-`set -e` care as above; here an empty answer means
        # cancel, so an unattended update stops rather than pressing on
        # without the rollback it expected to have.
        CONTINUE=""
        ui_ask CONTINUE "Continue without a backup?" "y/N" || CONTINUE=""
        if [ "$CONTINUE" != "y" ] && [ "$CONTINUE" != "Y" ]; then
            ui_fail "Update cancelled."
            exit 1
        fi
        rm -f "$BACKUP_FILE"
        BACKUP_FILE=""
    fi
fi

# ============================================
# Step 4: Pull New Images
# ============================================
ui_step 4 7 "Images"

# IMAGE_TAG pinned to a release from before rspamd and nginx were published as
# images will not find them: CI only started tagging those two from this
# version on, and `docker compose pull` fails on a manifest that does not
# exist. Caught here so the message names the setting instead of a registry
# 404. Everyone on the default `latest` sails past this.
if [ -n "${IMAGE_TAG:-}" ] && [ "$IMAGE_TAG" != "latest" ]; then
    if ! docker manifest inspect \
        "ghcr.io/${GITHUB_REPOSITORY:-roncanfil/una.email}/rspamd:${IMAGE_TAG}" \
        > /dev/null 2>&1; then
        ui_fail "No rspamd image published at IMAGE_TAG=$IMAGE_TAG."
        ui_note "Rspamd and Nginx are published images as of this release; tags"
        ui_note "older than it only cover web and mail. Set IMAGE_TAG=latest in"
        ui_note ".env (or pin a tag from this release onwards) and re-run."
        exit 1
    fi
fi

# Every update leaves the images it replaced behind, untagged: four of them,
# about 1.9GB, each time. Nothing here ever removed them, and on a 24GB box
# seven updates had put 9GB of them on disk. They are not a rollback -- a
# failed migration restores the database, not the images -- so they go:
# leftovers from earlier updates now, before the download needs the room, and
# the ones this update replaces at the end.
#
# Only untagged images from this install's own repositories, so an image
# some other project on the box left dangling is not ours to delete.
prune_replaced_images() {
    local repos
    repos=$(docker compose config --images 2>/dev/null | sed 's/[:@][^/]*$//' | sort -u || true)
    [ -z "$repos" ] && return 0
    local removed=0
    while read -r id repo; do
        [ -z "$id" ] && continue
        if printf '%s\n' "$repos" | grep -qxF "$repo"; then
            docker rmi "$id" > /dev/null 2>&1 && removed=$((removed + 1))
        fi
    done < <(docker images --filter dangling=true --format '{{.ID}} {{.Repository}}')
    if [ "$removed" -gt 0 ]; then
        ui_ok "Removed $removed replaced image(s)"
    fi
}

# Free space where Docker keeps its images, in KB.
docker_free_kb() {
    local root
    root=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null)
    df -Pk "${root:-/var/lib/docker}" 2>/dev/null | awk 'NR==2 {print $4}' || true
}

prune_replaced_images

# A pull that runs out of disk half way leaves layers nobody can use, and a
# full disk is also where Postgres stops accepting writes -- so stop here,
# with nothing changed, rather than find out part way through. 2GB is a
# full set of new images with a little room to spare.
FREE_KB=$(docker_free_kb)
if [ -n "$FREE_KB" ] && [ "$FREE_KB" -lt 2097152 ]; then
    ui_fail "Only $((FREE_KB / 1024))MB free for Docker; this update needs about 2GB."
    ui_note "See what is using the space:"
    ui_cmd "docker system df"
    ui_note "Nothing has been changed. Free some space, then run ./update.sh again."
    exit 1
fi

ui_spin "Downloading updates" "Images updated" docker compose pull

# ============================================
# Step 5: Restart Services
# ============================================
ui_step 5 7 "Restarting services"

ui_spin "Stopping containers" "Containers stopped" docker compose down
ui_spin "Starting containers" "Containers started" docker compose up -d

if ! ui_wait "Waiting for Postgres" "Postgres ready" 60 1 \
    docker compose exec -T postgres pg_isready -U una_email; then
    ui_fail "Postgres did not become ready within 60 seconds."
    docker compose logs --tail 40 postgres 2>&1 | ui_indent
    exit 1
fi

# wget: the web image has no curl.
if ! ui_wait "Waiting for the web container" "Web container responding" 60 2 \
    docker compose exec -T web wget -q -O /dev/null http://localhost:3000; then
    ui_warn "Web container not responding yet; attempting migrations anyway."
fi

echo ""
docker compose ps --format "table {{.Name}}\t{{.Status}}" | ui_indent

# ============================================
# Step 6: Run Migrations
# ============================================
ui_step 6 7 "Database migrations"

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
if docker compose exec -T web test -f scripts/baseline-migrations.js 2>/dev/null; then
    if ! ui_spin "Recording any migrations this database already has" "Migration history recorded" \
        docker compose exec -T web node scripts/baseline-migrations.js; then
        ui_warn "Could not record the existing migration history."
        ui_note "The migration step below will report what went wrong."
    fi
else
    ui_warn "This web image predates the baseline helper; skipping."
    ui_note "If migrations fail with P3005, re-run update.sh once a newer"
    ui_note "image has been pulled."
fi

if ! ui_spin "Applying database migrations" "Migrations complete" \
    docker compose exec -T web npx prisma migrate deploy; then
    echo ""

    if [ -n "$BACKUP_FILE" ]; then
        ui_run "Rolling back"
        ui_spin "Stopping containers" "Containers stopped" docker compose down
        # Brings up the same PostgreSQL the backup was just taken from.
        ui_spin "Starting Postgres" "Postgres started" docker compose up -d postgres
        ui_wait "Waiting for Postgres" "Postgres ready" 60 1 \
            docker compose exec -T postgres pg_isready -U una_email || true
        # ON_ERROR_STOP: without it psql skips what it cannot apply and still
        # exits 0, so a rollback that only half worked would announce itself as
        # a success. A plain pg_dump has no DROPs of its own either, which is
        # why the database is recreated rather than restored over.
        restore_database() {
            docker compose exec -T postgres psql -U una_email -d postgres -v ON_ERROR_STOP=1 \
                -c "DROP DATABASE IF EXISTS una_email WITH (FORCE)" \
                -c "CREATE DATABASE una_email OWNER una_email" > /dev/null &&
            docker compose exec -T postgres psql -U una_email una_email -v ON_ERROR_STOP=1 < "$BACKUP_FILE"
        }
        ui_spin "Restoring the database" "" restore_database
        ui_spin "Starting containers" "Containers started" docker compose up -d
        # Only the database goes back. The images pulled in step 4 stay, so
        # what is running now is the new release on the pre-update data --
        # say that, rather than "previous state", which it is not.
        ui_ok "Database restored from $BACKUP_FILE"
        ui_note "The new images are still in place: the containers now running"
        ui_note "are this release, on your data as it was before the update."
    else
        ui_warn "No backup was taken, so nothing was rolled back."
        ui_note "The database is part-way through a migration and the new"
        ui_note "images are already pulled. If you have a dump of your own:"
        ui_cmd "./restore.sh your-dump.sql"
    fi

    echo ""
    ui_text "Please contact support@una.email with the error above."
    exit 1
fi

# ============================================
# Step 7: Health Check
# ============================================
ui_step 7 7 "Verification"

# Check web interface
ui_spin "Letting the services settle" "" sleep 5
if docker compose exec -T web wget -q -O /dev/null http://localhost:3000 > /dev/null 2>&1; then
    ui_status ok "Web interface" "responding"
else
    ui_status warn "Web interface" "not responding (may still be starting)"
fi

# Check Postfix
if docker compose exec -T postfix postfix status > /dev/null 2>&1; then
    ui_status ok "Mail server" "running"
else
    ui_status warn "Mail server" "check logs: docker compose logs postfix"
fi

# Check Rspamd
if docker compose exec -T rspamd rspamadm configtest > /dev/null 2>&1; then
    ui_status ok "Spam filter" "running"
else
    ui_status warn "Spam filter" "check logs: docker compose logs rspamd"
fi

# Rspamd must actually be adding the headers the web app reads. An empty
# `use` list means milter_headers never loaded, and it stores every inbound
# message with a NULL spam score.
if docker compose exec -T rspamd rspamadm configdump milter_headers 2>/dev/null \
    | grep -q 'x-spamd-result'; then
    ui_status ok "Spam headers" "configured"
else
    ui_status warn "Spam headers" "milter_headers is empty: inbound mail will have no spam score"
    ui_note "The rspamd image ships this config, so an empty list means the"
    ui_note "image is stale or an override.d file replaced it. Check:"
    ui_cmd "docker compose exec rspamd rspamadm configdump milter_headers"
    ui_cmd "ls rspamd/override.d/"
fi

# The controller owns /learnspam and /learnham. If it still accepts the image
# default "q1", reporting spam is an unauthenticated endpoint.
# Asked from the postfix container, not the rspamd one: the rspamd image ships
# neither curl nor wget. postfix has curl and sits on the same compose network.
RSPAMD_CODE=$(docker compose exec -T postfix \
    curl -s -o /dev/null -w '%{http_code}' -H "Password: q1" \
    http://rspamd:11334/stat 2>/dev/null || echo "000")
if [ "$RSPAMD_CODE" = "401" ]; then
    ui_status ok "Rspamd controller" "password protected (default 'q1' rejected)"
elif [ "$RSPAMD_CODE" = "200" ]; then
    ui_status fail "Rspamd controller" "still accepting the default password 'q1'"
    ui_note "RSPAMD_PASSWORD is not reaching the container."
    ui_note "Check .env, then:"
    ui_cmd "docker compose up -d rspamd"
else
    ui_status warn "Rspamd controller" "could not reach it (HTTP $RSPAMD_CODE)"
fi

# ============================================
# Complete
# ============================================
ui_done "Update complete"

# The containers are on the new images now, so the ones they replaced are
# untagged and unused.
prune_replaced_images

# One dump per update, and nothing ever removed them. Keep the ten newest:
# the one this run just took, and enough history to reach back past a bad
# week. Only this script's own backup_*.sql, never anything else in backups/.
if [ -d backups ]; then
    # `|| true` so a failing listing can never end the script under set -e.
    OLD_BACKUPS=$(ls -1t backups/backup_*.sql 2>/dev/null | tail -n +11 || true)
    if [ -n "$OLD_BACKUPS" ]; then
        printf '%s\n' "$OLD_BACKUPS" | xargs rm -f
        ui_ok "Kept the 10 newest backups, removed $(printf '%s\n' "$OLD_BACKUPS" | wc -l | tr -d ' ')"
    fi
fi

if [ -n "$BACKUP_FILE" ]; then
    ui_kv "Backup" "$BACKUP_FILE"
    ui_kv "" "${UI_DIM}(the 10 newest are kept; older ones go on each update)${UI_RESET}"
fi

FREE_KB=$(docker_free_kb)
if [ -n "$FREE_KB" ]; then
    ui_kv "Disk" "$((FREE_KB / 1024))MB free for Docker"
fi
ui_kv "Web interface" "https://$WEB_SUBDOMAIN.$DOMAIN"
echo ""
ui_text "Useful commands:"
ui_cmd "docker compose logs -f       # all logs"
ui_cmd "docker compose ps            # service status"
echo ""
