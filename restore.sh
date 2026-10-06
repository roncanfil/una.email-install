#!/bin/bash

# UNA.Email Restore Script
#
# Replaces the database with the contents of a dump file.
#
#   ./restore.sh backups/backup_20260922_181500.sql
#   ./restore.sh backups/una-backup_20260922_181500.tar.gz --with-secrets
#   ./restore.sh mailbox.sql.gz --yes
#   ./restore.sh mailbox.sql --check
#
# Two kinds of file go in here. A bare pg_dump restores the database and
# nothing else. A full archive from backup.sh also carries the attachment
# files and, when asked for, the secrets and DKIM keys -- which is what makes
# it a way to stand this install up on another machine.
#
# This is a terminal job rather than a screen in the app on purpose: a dump of
# a real mailbox is measured in gigabytes, and pushing one through a browser
# upload means buffering it, timing out on it, and letting the web container
# spawn a psql it has no business spawning. Export belongs in the UI. Import
# belongs here.
#
# What it does, in order:
#
#   1. Reads the file without changing anything: gzip or plain, that it really
#      is a pg_dump, and which PostgreSQL wrote it.
#   2. Takes a dump of what is there now, so an unwanted restore is itself
#      reversible.
#   3. Stops the stack apart from PostgreSQL, so nothing writes half way
#      through, then drops and recreates the database -- a plain pg_dump has no
#      DROP statements of its own, so restoring onto a live database merges two
#      datasets rather than replacing one.
#   4. Restores with ON_ERROR_STOP, so a failure is a failure and not a
#      half-populated database that reported success.
#   5. Brings everything back up and runs the migrations, because a dump taken
#      from an older release restores an older schema.

set -e
# The restore is a pipeline -- `gzip -dc | psql` -- and without pipefail a
# truncated or corrupt dump would be reported as a successful restore whenever
# psql happened to exit 0 on the part that did arrive. Every other pipeline in
# this file is written so that a reader closing early (`head`, `grep -q`)
# cannot be mistaken for a failure; see update.sh for the same trap.
set -o pipefail

# shellcheck source=lib/ui.sh
. "$(dirname "$0")/lib/ui.sh"

DB_NAME="una_email"
DB_USER="una_email"
BACKUP_DIR="backups"

DUMP_FILE=""
ASSUME_YES="no"
TAKE_BACKUP="yes"
CHECK_ONLY="no"
WITH_SECRETS="no"

# Set when the file turns out to be a backup.sh archive rather than a bare dump.
ARCHIVE_MODE="no"
ARCHIVE_DIR=""
# The SQL actually restored: the given file, or the one inside the archive.
DUMP_SQL=""

usage() {
    cat <<'USAGE'
Usage: ./restore.sh <file> [options]

  <file>         A pg_dump SQL file, gzipped or not (.sql / .sql.gz), or a
                 full archive from ./backup.sh (.tar.gz / .tar).

Options:
  --with-secrets Archive only. Also put back SESSION_SECRET, RELAY_KEY and the
                 VAPID keys from the archive, and its dkim/ directory. This is
                 what a move to another server needs: without it everyone is
                 logged out, the stored relay password cannot be decrypted,
                 every push subscription is dead, and outbound mail is signed
                 with a key your DNS does not publish. Your DOMAIN, DB_PASSWORD
                 and RSPAMD_PASSWORD are always left as this install has them.
  --yes          Do not ask for confirmation. For scripts and cron.
  --no-backup    Skip the safety backup taken before anything is replaced.
                 Only sensible on a server with nothing on it yet.
  --check        Inspect the file and report what would happen. Touches
                 nothing -- no stack is stopped and no data is written.
  -h, --help     This text.
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --yes|-y) ASSUME_YES="yes" ;;
        --no-backup) TAKE_BACKUP="no" ;;
        --with-secrets) WITH_SECRETS="yes" ;;
        --check) CHECK_ONLY="yes" ;;
        -h|--help) usage; exit 0 ;;
        -*)
            ui_fail "Unknown option: $1"
            echo ""
            usage
            exit 1
            ;;
        *)
            if [ -n "$DUMP_FILE" ]; then
                ui_fail "More than one file given: '$DUMP_FILE' and '$1'"
                exit 1
            fi
            DUMP_FILE="$1"
            ;;
    esac
    shift
done

ui_banner "Restore"

if [ -z "$DUMP_FILE" ]; then
    usage
    exit 1
fi

if [ ! -f .env ]; then
    ui_fail "No .env file found."
    ui_note "Run this from the directory UNA Email is installed in."
    exit 1
fi

if [ ! -r "$DUMP_FILE" ]; then
    ui_fail "Cannot read '$DUMP_FILE'."
    exit 1
fi

# ============================================
# Step 1: Inspect the file
# ============================================
ui_step 1 8 "Checking the file"

# Gzip by content, not by name: a file saved as `backup.sql` that is actually
# gzipped is a common way to arrive here, and so is a `.gz` that is not.
if gzip -t "$DUMP_FILE" 2>/dev/null; then
    COMPRESSED="yes"
    READ_DUMP="gzip -dc"
else
    COMPRESSED="no"
    READ_DUMP="cat"
fi

# An archive from backup.sh is a tar with a MANIFEST in it. Unpacked here, so
# everything below works on the database.sql inside it exactly as it would on a
# dump given directly -- the checks are the same checks.
if tar tf "$DUMP_FILE" > /dev/null 2>&1 \
   && tar tf "$DUMP_FILE" 2>/dev/null | grep -q "/MANIFEST$"; then
    ARCHIVE_MODE="yes"
    ARCHIVE_STAGE=$(mktemp -d)
    trap 'rm -rf "$ARCHIVE_STAGE"' EXIT
    ui_spin "Unpacking the archive" "Archive unpacked" tar xf "$DUMP_FILE" -C "$ARCHIVE_STAGE"
    ARCHIVE_DIR=$(find "$ARCHIVE_STAGE" -mindepth 1 -maxdepth 1 -type d | head -n 1)

    if [ -z "$ARCHIVE_DIR" ] || [ ! -f "$ARCHIVE_DIR/database.sql" ]; then
        ui_fail "That archive has a MANIFEST but no database.sql in it."
        ui_note "It is not one ./backup.sh wrote, or it is incomplete."
        exit 1
    fi

    echo ""
    ui_indent < "$ARCHIVE_DIR/MANIFEST"
    echo ""

    DUMP_SQL="$ARCHIVE_DIR/database.sql"
    READ_DUMP="cat"
    COMPRESSED="no"
else
    DUMP_SQL="$DUMP_FILE"
fi

DUMP_SIZE=$(ls -lh "$DUMP_FILE" | awk '{print $5}')

# pg_dump writes its header in the first few dozen lines. `head` closes the
# pipe early, which kills the reader with SIGPIPE -- harmless, but `set -e`
# would end the script on it, so each of these is allowed to fail.
HEADER=$($READ_DUMP "$DUMP_SQL" 2>/dev/null | head -n 50 || true)

if ! printf '%s' "$HEADER" | grep -q "PostgreSQL database dump"; then
    ui_fail "'$DUMP_FILE' does not look like a pg_dump file."

    # Say which wrong thing it is. The magic bytes are a better answer than a
    # preview of binary, and a damaged gzip is the likeliest of the three --
    # `gzip -t` failed above, so a file that still starts 1f 8b arrived here
    # incomplete rather than uncompressed.
    MAGIC=$(head -c 2 "$DUMP_SQL" | od -An -tx1 | tr -d ' \n' || true)
    case "$MAGIC" in
        1f8b)
            ui_note "It starts like a gzip file but does not decompress, so it is"
            ui_note "damaged or incomplete. A transfer cut short is the usual"
            ui_note "reason. Check its size against the original and copy it"
            ui_note "again."
            ;;
        5047) # "PG", as in PGDMP
            ui_note "It is a custom-format dump (pg_dump -Fc). This script restores"
            ui_note "plain SQL, which is what UNA's own backups are. Convert it:"
            ui_cmd "pg_restore -f converted.sql '$DUMP_FILE'"
            ;;
        *)
            ui_note "The first lines of a dump this script can restore say"
            ui_note "'-- PostgreSQL database dump'. What is in this file starts:"
            ui_note
            # Non-printable bytes go through as `?`: a wrong file is often
            # binary, and sed on binary prints an encoding error instead of the
            # preview this line exists to give.
            printf '%s\n' "$HEADER" | head -n 5 \
                | LC_ALL=C tr -c '[:print:]\n' '?' \
                | LC_ALL=C cut -c 1-72 \
                | LC_ALL=C sed 's/^/        /' || true
            ;;
    esac
    exit 1
fi

# "Dumped from database version 18.1" -- the major is what matters. Restoring
# a newer major into an older server is the direction that breaks.
DUMP_PG_MAJOR=$(printf '%s' "$HEADER" \
    | sed -n 's/.*Dumped from database version \([0-9]*\).*/\1/p' \
    | head -n 1 || true)

if [ "$ARCHIVE_MODE" = "yes" ]; then
    ui_kv "File" "$DUMP_FILE ($DUMP_SIZE, full backup archive)"
    if [ -s "$ARCHIVE_DIR/attachments.tar" ]; then
        ui_kv "Attachments" "$(ls -lh "$ARCHIVE_DIR/attachments.tar" | awk '{print $5}'), will replace this install's"
    else
        ui_kv "Attachments" "none in the archive; this install's are left alone"
    fi
    if [ "$WITH_SECRETS" = "yes" ]; then
        ui_kv "Secrets" "SESSION_SECRET, RELAY_KEY, VAPID_* and dkim/ will be restored"
    else
        ui_kv "Secrets" "left alone (pass --with-secrets to restore them)"
    fi
elif [ "$COMPRESSED" = "yes" ]; then
    ui_kv "File" "$DUMP_FILE ($DUMP_SIZE, gzipped)"
else
    ui_kv "File" "$DUMP_FILE ($DUMP_SIZE)"
fi
ui_kv "Written by" "PostgreSQL ${DUMP_PG_MAJOR:-unknown}"
ui_kv "Target" "database '$DB_NAME' on this install"

# ============================================
# Step 2: Check the server
# ============================================
ui_step 2 8 "Checking PostgreSQL"

if ! docker compose config --quiet 2>/dev/null; then
    ui_fail "Could not read docker-compose.yml."
    docker compose config --quiet 2>&1 | ui_indent || true
    exit 1
fi

# Same derivation, and the same pipefail care, as backup.sh and update.sh.
PROJECT="$(docker compose config --format json 2>/dev/null \
    | sed -n '/"name":/{s/.*"name": *"\([^"]*\)".*/\1/p;q;}')"
ATTACHMENTS_VOL="${PROJECT}_attachments_data"

# It may be stopped, which is fine -- we start it ourselves below. What we
# cannot do is compare versions without it, so start it now if it is down.
if ! docker compose ps --services --filter status=running 2>/dev/null | grep -x postgres > /dev/null; then
    ui_info "PostgreSQL is not running. Starting it."
    ui_spin "Starting PostgreSQL" "PostgreSQL started" docker compose up -d postgres
fi

if ! ui_wait "Waiting for PostgreSQL" "" 60 1 \
    docker compose exec -T postgres pg_isready -U "$DB_USER"; then
    ui_fail "PostgreSQL did not come up."
    ui_note "Check:"
    ui_cmd "docker compose logs postgres"
    exit 1
fi

SERVER_PG_MAJOR=$(docker compose exec -T postgres \
    psql -U "$DB_USER" -d postgres -tAc "SHOW server_version" 2>/dev/null \
    | cut -d. -f1 | tr -d '[:space:]')

ui_ok "PostgreSQL $SERVER_PG_MAJOR is running"

if [ -n "$DUMP_PG_MAJOR" ] && [ -n "$SERVER_PG_MAJOR" ] \
   && [ "$DUMP_PG_MAJOR" -gt "$SERVER_PG_MAJOR" ]; then
    ui_fail "That dump came from PostgreSQL $DUMP_PG_MAJOR and this server is $SERVER_PG_MAJOR."
    ui_note "A dump does not restore into an older major."
    ui_note "Upgrade this install first, then restore."
    exit 1
fi

if [ "$CHECK_ONLY" = "yes" ]; then
    ui_done "Check only. Nothing changed."
    ui_text "The file holds a PostgreSQL $DUMP_PG_MAJOR dump and this server is"
    ui_text "$SERVER_PG_MAJOR, so it would restore. To do it:"
    echo ""
    if [ "$ARCHIVE_MODE" = "yes" ]; then
        ui_cmd "./restore.sh $DUMP_FILE --with-secrets    # a move to this server"
        ui_cmd "./restore.sh $DUMP_FILE                   # data only, keep this install's keys"
    else
        ui_cmd "./restore.sh $DUMP_FILE"
    fi
    echo ""
    exit 0
fi

# ============================================
# Step 3: Confirm
# ============================================
if [ "$ASSUME_YES" != "yes" ]; then
    ui_step 3 8 "Confirm"
    ui_warn "Every message, account, alias and setting in '$DB_NAME' will be"
    ui_note "replaced by the contents of that file."
    if [ "$ARCHIVE_MODE" = "yes" ] && [ -s "$ARCHIVE_DIR/attachments.tar" ]; then
        ui_warn "Every attachment file on this install will be replaced too."
    fi
    if [ "$WITH_SECRETS" = "yes" ]; then
        ui_warn "SESSION_SECRET, RELAY_KEY and the VAPID keys in .env, and the"
        ui_note "contents of dkim/, will be replaced by the archive's."
    fi
    echo ""
    # A typed word, not a keystroke: y is one slip away from being the answer
    # to something else, and this one is not undoable without the dump below.
    CONFIRM=""
    ui_ask CONFIRM "Type 'restore' to continue:" || CONFIRM=""
    if [ "$CONFIRM" != "restore" ]; then
        ui_fail "Restore cancelled. Nothing was changed."
        exit 1
    fi
fi

# ============================================
# Step 4: Safety dump
# ============================================
ui_step 4 8 "Backing up what is there now"

SAFETY_FILE=""
if [ "$TAKE_BACKUP" = "no" ]; then
    ui_info "Skipped (--no-backup). This restore cannot be undone."
elif [ "$ARCHIVE_MODE" = "yes" ]; then
    # A dump alone is not a way back from an archive restore: the attachments
    # and possibly the keys are being replaced too. So the safety copy is a
    # full one, taken by the same script that made the archive rather than by a
    # second copy of its logic here.
    full_backup() { ./backup.sh --output "$BACKUP_DIR" > /dev/null 2>&1; }
    if ui_spin "Taking a full backup of this install first" "" full_backup; then
        SAFETY_FILE=$(ls -t "$BACKUP_DIR"/una-backup_*.tar.gz 2>/dev/null | head -n 1 || true)
        ui_ok "Saved: $SAFETY_FILE ($(ls -lh "$SAFETY_FILE" | awk '{print $5}'))"
    else
        SAFETY_FILE=""
        ui_warn "Could not take a full backup."
        ui_note "That is expected on a server with nothing on it yet, and a"
        ui_note "problem if this one has mail on it."
        CONTINUE=""
        ui_ask CONTINUE "Continue without a way back?" "y/N" || CONTINUE=""
        if [ "$CONTINUE" != "y" ] && [ "$CONTINUE" != "Y" ]; then
            ui_fail "Restore cancelled. Nothing was changed."
            exit 1
        fi
    fi
else
    mkdir -p "$BACKUP_DIR"
    SAFETY_FILE="$BACKUP_DIR/pre-restore_$(date +%Y%m%d_%H%M%S).sql"
    dump_current() {
        docker compose exec -T postgres pg_dump -U "$DB_USER" "$DB_NAME" > "$SAFETY_FILE" 2>/dev/null
    }
    if ui_spin "Dumping the current database" "" dump_current; then
        ui_ok "Saved: $SAFETY_FILE ($(ls -lh "$SAFETY_FILE" | awk '{print $5}'))"
    else
        rm -f "$SAFETY_FILE"
        SAFETY_FILE=""
        ui_warn "Could not dump the current database."
        ui_note "That is expected if it is empty or already broken, and a"
        ui_note "problem if it is neither."
        CONTINUE=""
        ui_ask CONTINUE "Continue without a way back?" "y/N" || CONTINUE=""
        if [ "$CONTINUE" != "y" ] && [ "$CONTINUE" != "Y" ]; then
            ui_fail "Restore cancelled. Nothing was changed."
            exit 1
        fi
    fi
fi

# ============================================
# Step 5: Quiesce and replace
# ============================================
ui_step 5 8 "Restoring"

# Everything but PostgreSQL goes down. The web container holds a connection
# pool and the outbox scheduler writes on a timer; either would be writing
# into a database being dropped out from under it.
ui_spin "Stopping the stack" "Stack stopped" docker compose down
ui_spin "Starting PostgreSQL on its own" "PostgreSQL started" docker compose up -d postgres
ui_wait "Waiting for PostgreSQL" "PostgreSQL ready" 60 1 \
    docker compose exec -T postgres pg_isready -U "$DB_USER" || true

# A plain pg_dump contains CREATE, not DROP. Restoring it onto the existing
# database would leave every old row in place and fail on every object that
# already exists. Dropping the database is what makes this a restore rather
# than a merge. Connected to `postgres`, because you cannot drop the database
# you are connected to.
recreate_database() {
    docker compose exec -T postgres psql -U "$DB_USER" -d postgres -v ON_ERROR_STOP=1 \
        -c "DROP DATABASE IF EXISTS $DB_NAME WITH (FORCE)" \
        -c "CREATE DATABASE $DB_NAME OWNER $DB_USER" > /dev/null
}
ui_spin "Dropping and recreating '$DB_NAME'" "'$DB_NAME' recreated, empty" recreate_database

mkdir -p "$BACKUP_DIR"
RESTORE_LOG="$BACKUP_DIR/restore_$(date +%Y%m%d_%H%M%S).log"

# ON_ERROR_STOP, or psql reports success having skipped every statement that
# failed. The log is where the reason lives when it does fail; a dump of any
# size produces far too much output to put on screen.
restore_dump() {
    $READ_DUMP "$DUMP_SQL" | docker compose exec -T postgres \
        psql -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 --quiet \
        > "$RESTORE_LOG" 2>&1
}
ui_info "This is the slow part. psql's output goes to $RESTORE_LOG"
if ! ui_spin "Restoring the database" "Restored" restore_dump; then
    ui_note "Last lines of $RESTORE_LOG:"
    tail -n 20 "$RESTORE_LOG" | ui_indent
    ui_note
    if [ -n "$SAFETY_FILE" ]; then
        ui_note "The database is now part-restored. To put back what you had:"
        ui_cmd "./restore.sh $SAFETY_FILE"
    else
        ui_note "No safety dump was taken, so there is nothing to put back."
    fi
    ui_note
    ui_note "Everything but PostgreSQL is still stopped, deliberately: the"
    ui_note "database is part-restored and bringing the app up against it"
    ui_note "would only add to what has to be undone."
    ui_note
    ui_note "Send the log to support@una.email if the reason is not obvious."
    exit 1
fi

# ============================================
# Step 6: Files and keys
# ============================================
if [ "$ARCHIVE_MODE" = "yes" ]; then
    ui_step 6 8 "Attachments and keys"

    if [ -s "$ARCHIVE_DIR/attachments.tar" ]; then
        # Replace, not merge -- the same reason the database is dropped and
        # recreated. Files this install has that the archive does not are files
        # the restored rows know nothing about, and leaving them would be
        # keeping two installs' attachments in one tree.
        ui_spin "Replacing the attachments volume" "Attachments restored" \
            docker run --rm -v "$ATTACHMENTS_VOL":/data -v "$ARCHIVE_DIR":/in:ro alpine \
            sh -c 'rm -rf /data/* /data/.[!.]* 2>/dev/null; tar xf /in/attachments.tar -C /data'
    else
        ui_info "No attachments in the archive. Leaving this install's alone."
    fi

    if [ "$WITH_SECRETS" = "yes" ]; then
        SECRETS_BACKUP="$BACKUP_DIR/secrets-before-restore_$(date +%Y%m%d_%H%M%S)"
        mkdir -p "$SECRETS_BACKUP"
        cp .env "$SECRETS_BACKUP/env"
        [ -d dkim ] && cp -R dkim "$SECRETS_BACKUP/dkim"
        # `go-rwx`, not `-R 600`: 600 on a directory takes away the execute
        # bit it needs to be entered, and the one copy of your previous keys
        # becomes a directory you cannot read out of.
        chmod -R go-rwx "$SECRETS_BACKUP" 2>/dev/null || true

        # Only the keys whose value has to be the *same* value it was. DOMAIN,
        # DB_PASSWORD and RSPAMD_PASSWORD are this machine's business: the
        # database role on a fresh install was created with the local
        # DB_PASSWORD and would stop accepting the app the moment .env said
        # something else.
        set_env_key() {
            local key="$1"
            local file=".env"
            local value
            value=$(grep -E "^[[:space:]]*${key}=" "$ARCHIVE_DIR/env" | head -n 1 | cut -d= -f2- || true)
            [ -z "$value" ] && return 0
            if grep -qE "^[[:space:]]*${key}=" "$file"; then
                # Through the environment rather than `awk -v`, which would read
                # backslashes in a secret as escapes, and never through sed,
                # whose replacement text treats / and & as syntax. Base64 keys
                # contain both.
                RESTORED_VALUE="$value" awk -v k="$key" \
                    '$0 ~ "^[[:space:]]*" k "=" { print k "=" ENVIRON["RESTORED_VALUE"]; next } { print }' \
                    "$file" > "$file.tmp" && mv "$file.tmp" "$file"
            else
                printf '%s=%s\n' "$key" "$value" >> "$file"
            fi
            ui_ok "$key restored"
        }

        for key in SESSION_SECRET RELAY_KEY VAPID_PUBLIC_KEY VAPID_PRIVATE_KEY VAPID_SUBJECT; do
            set_env_key "$key"
        done

        if [ -d "$ARCHIVE_DIR/dkim" ]; then
            find dkim -mindepth 1 ! -name '.gitkeep' -delete 2>/dev/null || true
            cp -R "$ARCHIVE_DIR/dkim/." dkim/
            ui_ok "dkim/ restored"
        fi

        ui_info "What those were before: $SECRETS_BACKUP"

        # A domain mismatch is not something to fix silently. The restored
        # database names the old domain in its own rows, and the two have to
        # agree or mail routes to an address this install does not serve.
        ARCHIVE_DOMAIN=$(grep -E '^[[:space:]]*DOMAIN=' "$ARCHIVE_DIR/env" | head -n 1 | cut -d= -f2- || true)
        LOCAL_DOMAIN=$(grep -E '^[[:space:]]*DOMAIN=' .env | head -n 1 | cut -d= -f2- || true)
        if [ -n "$ARCHIVE_DOMAIN" ] && [ "$ARCHIVE_DOMAIN" != "$LOCAL_DOMAIN" ]; then
            ui_warn "The archive was taken from '$ARCHIVE_DOMAIN' and this install"
            ui_note "is '$LOCAL_DOMAIN'. DOMAIN was left as this install has it,"
            ui_note "but the restored database still describes the old one."
            ui_note "Check Settings > Domains before trusting outbound mail."
        fi
    else
        ui_info "Secrets left alone. If this is a move to a new server, the"
        ui_note "sessions, the stored relay password, push notifications and"
        ui_note "DKIM signing all depend on the old values. Re-run with"
        ui_note "--with-secrets."
    fi
fi

# ============================================
# Step 7: Bring it back up
# ============================================
ui_step 7 8 "Starting up"

ui_spin "Starting the stack" "Stack started" docker compose up -d

# A dump from an older release restores an older schema. `migrate deploy` is
# what makes it the schema this release expects, and it is a no-op when the
# dump is current.
ui_wait "Waiting for the web container" "" 60 1 \
    docker compose exec -T web test -f package.json || true

# A dump taken from a box built by `prisma db push` carries the schema and an
# empty _prisma_migrations, and `migrate deploy` refuses that with P3005. The
# same helper update.sh runs records what the database already has so deploy
# can apply the rest. It does nothing when the dump is current.
if docker compose exec -T web test -f scripts/baseline-migrations.js 2>/dev/null; then
    if ! ui_spin "Recording any migrations this database already has" "Migration history recorded" \
        docker compose exec -T web node scripts/baseline-migrations.js; then
        ui_warn "Could not record the existing migration history."
        ui_note "The migration step below will report what went wrong."
    fi
else
    ui_warn "This web image predates the baseline helper; skipping."
fi

if ! ui_spin "Applying database migrations" "Migrations complete" \
    docker compose exec -T web npx prisma migrate deploy; then
    ui_note
    ui_note "The migrations failed against the restored database. The data is"
    ui_note "in, but the schema is behind what this release wants."
    if [ -n "$SAFETY_FILE" ]; then
        ui_note "To go back:"
        ui_cmd "./restore.sh $SAFETY_FILE"
    fi
    ui_note "Send the error above to support@una.email."
    exit 1
fi

# ============================================
# Step 8: Verify
# ============================================
ui_step 8 8 "Verification"

COUNTS=$(docker compose exec -T postgres psql -U "$DB_USER" -d "$DB_NAME" -tA -F' ' \
    -c "SELECT
          (SELECT count(*) FROM users),
          (SELECT count(*) FROM accounts),
          (SELECT count(*) FROM aliases),
          (SELECT count(*) FROM emails)" 2>/dev/null || true)

if [ -n "$COUNTS" ]; then
    read -r N_USERS N_ACCOUNTS N_ALIASES N_EMAILS <<< "$COUNTS"
    ui_kv "Users" "$N_USERS"
    ui_kv "Mailboxes" "$N_ACCOUNTS"
    ui_kv "Aliases" "$N_ALIASES"
    ui_kv "Messages" "$N_EMAILS"
else
    ui_warn "Could not read row counts. Check: docker compose logs postgres"
fi

ui_spin "Letting the services settle" "" sleep 5
if docker compose exec -T web wget -q -O /dev/null http://localhost:3000 > /dev/null 2>&1; then
    ui_status ok "Web interface" "responding"
else
    ui_status warn "Web interface" "not responding (may still be starting)"
fi

ui_done "Restore complete"
if [ -n "$SAFETY_FILE" ]; then
    ui_kv "Previous data" "$SAFETY_FILE"
    ui_kv "" "${UI_DIM}(delete it once you are happy with the restore)${UI_RESET}"
    echo ""
fi
if [ "$ARCHIVE_MODE" = "yes" ] && [ "$WITH_SECRETS" = "yes" ]; then
    ui_info "The DKIM keys came across, so your existing DNS record still"
    ui_note "matches. TLS did not: run ./renew-ssl.sh on this machine."
    echo ""
fi
ui_text "Sign in and check your mail before deleting anything."
echo ""
