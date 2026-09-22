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
            echo "❌ Unknown option: $1"
            echo ""
            usage
            exit 1
            ;;
        *)
            if [ -n "$DUMP_FILE" ]; then
                echo "❌ More than one file given: '$DUMP_FILE' and '$1'"
                exit 1
            fi
            DUMP_FILE="$1"
            ;;
    esac
    shift
done

echo ""
echo "=========================================="
echo "       UNA.Email Restore"
echo "=========================================="
echo ""

if [ -z "$DUMP_FILE" ]; then
    usage
    exit 1
fi

if [ ! -f .env ]; then
    echo "❌ No .env file found."
    echo "   Run this from the directory UNA Email is installed in."
    exit 1
fi

if [ ! -r "$DUMP_FILE" ]; then
    echo "❌ Cannot read '$DUMP_FILE'."
    exit 1
fi

# ============================================
# Step 1: Inspect the file
# ============================================
echo "Step 1: Checking the file"
echo "-------------------------"

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
    echo "📦 Unpacking the archive..."
    tar xf "$DUMP_FILE" -C "$ARCHIVE_STAGE"
    ARCHIVE_DIR=$(find "$ARCHIVE_STAGE" -mindepth 1 -maxdepth 1 -type d | head -n 1)

    if [ -z "$ARCHIVE_DIR" ] || [ ! -f "$ARCHIVE_DIR/database.sql" ]; then
        echo "❌ That archive has a MANIFEST but no database.sql in it."
        echo "   It is not one ./backup.sh wrote, or it is incomplete."
        exit 1
    fi

    echo ""
    sed 's/^/     /' "$ARCHIVE_DIR/MANIFEST"
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
    echo "❌ '$DUMP_FILE' does not look like a pg_dump file."
    echo ""

    # Say which wrong thing it is. The magic bytes are a better answer than a
    # preview of binary, and a damaged gzip is the likeliest of the three --
    # `gzip -t` failed above, so a file that still starts 1f 8b arrived here
    # incomplete rather than uncompressed.
    MAGIC=$(head -c 2 "$DUMP_SQL" | od -An -tx1 | tr -d ' \n' || true)
    case "$MAGIC" in
        1f8b)
            echo "   It starts like a gzip file but does not decompress, so it is"
            echo "   damaged or incomplete — a transfer cut short is the usual"
            echo "   reason. Check its size against the original and copy it"
            echo "   again."
            ;;
        5047) # "PG", as in PGDMP
            echo "   It is a custom-format dump (pg_dump -Fc). This script restores"
            echo "   plain SQL, which is what UNA's own backups are. Convert it:"
            echo ""
            echo "     pg_restore -f converted.sql '$DUMP_FILE'"
            ;;
        *)
            echo "   The first lines of a dump this script can restore say"
            echo "   '-- PostgreSQL database dump'. What is in this file starts:"
            echo ""
            # Non-printable bytes go through as `?`: a wrong file is often
            # binary, and sed on binary prints an encoding error instead of the
            # preview this line exists to give.
            printf '%s\n' "$HEADER" | head -n 5 \
                | LC_ALL=C tr -c '[:print:]\n' '?' \
                | LC_ALL=C sed 's/^/     /' || true
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
    echo "📦 File:       $DUMP_FILE ($DUMP_SIZE, full backup archive)"
    if [ -s "$ARCHIVE_DIR/attachments.tar" ]; then
        echo "📎 Attachments: $(ls -lh "$ARCHIVE_DIR/attachments.tar" | awk '{print $5}') — will replace this install's"
    else
        echo "📎 Attachments: none in the archive — this install's are left alone"
    fi
    if [ "$WITH_SECRETS" = "yes" ]; then
        echo "🔑 Secrets:    SESSION_SECRET, RELAY_KEY, VAPID_* and dkim/ will be restored"
    else
        echo "🔑 Secrets:    left alone (pass --with-secrets to restore them)"
    fi
elif [ "$COMPRESSED" = "yes" ]; then
    echo "📄 File:       $DUMP_FILE ($DUMP_SIZE, gzipped)"
else
    echo "📄 File:       $DUMP_FILE ($DUMP_SIZE)"
fi
echo "🐘 Written by: PostgreSQL ${DUMP_PG_MAJOR:-unknown}"
echo "🎯 Target:     database '$DB_NAME' on this install"
echo ""

# ============================================
# Step 2: Check the server
# ============================================
echo "Step 2: Checking PostgreSQL"
echo "---------------------------"

if ! docker compose config --quiet 2>/dev/null; then
    echo "❌ Could not read docker-compose.yml."
    docker compose config --quiet || true
    exit 1
fi

# Same derivation, and the same pipefail care, as backup.sh and update.sh.
PROJECT="$(docker compose config --format json 2>/dev/null \
    | sed -n '/"name":/{s/.*"name": *"\([^"]*\)".*/\1/p;q;}')"
ATTACHMENTS_VOL="${PROJECT}_attachments_data"

# It may be stopped, which is fine -- we start it ourselves below. What we
# cannot do is compare versions without it, so start it now if it is down.
if ! docker compose ps --services --filter status=running 2>/dev/null | grep -x postgres > /dev/null; then
    echo "🐘 PostgreSQL is not running — starting it."
    docker compose up -d postgres
fi

for _ in $(seq 1 60); do
    docker compose exec -T postgres pg_isready -U "$DB_USER" > /dev/null 2>&1 && break
    sleep 1
done

if ! docker compose exec -T postgres pg_isready -U "$DB_USER" > /dev/null 2>&1; then
    echo "❌ PostgreSQL did not come up. Check: docker compose logs postgres"
    exit 1
fi

SERVER_PG_MAJOR=$(docker compose exec -T postgres \
    psql -U "$DB_USER" -d postgres -tAc "SHOW server_version" 2>/dev/null \
    | cut -d. -f1 | tr -d '[:space:]')

echo "✅ PostgreSQL $SERVER_PG_MAJOR is running"

if [ -n "$DUMP_PG_MAJOR" ] && [ -n "$SERVER_PG_MAJOR" ] \
   && [ "$DUMP_PG_MAJOR" -gt "$SERVER_PG_MAJOR" ]; then
    echo ""
    echo "❌ That dump came from PostgreSQL $DUMP_PG_MAJOR and this server is"
    echo "   $SERVER_PG_MAJOR. A dump does not restore into an older major."
    echo "   Upgrade this install first, then restore."
    exit 1
fi
echo ""

if [ "$CHECK_ONLY" = "yes" ]; then
    echo "=========================================="
    echo "       Check only — nothing changed"
    echo "=========================================="
    echo ""
    echo "The file holds a PostgreSQL $DUMP_PG_MAJOR dump and this server is"
    echo "$SERVER_PG_MAJOR, so it would restore. To do it:"
    echo ""
    if [ "$ARCHIVE_MODE" = "yes" ]; then
        echo "  ./restore.sh $DUMP_FILE --with-secrets    # a move to this server"
        echo "  ./restore.sh $DUMP_FILE                   # data only, keep this install's keys"
    else
        echo "  ./restore.sh $DUMP_FILE"
    fi
    echo ""
    exit 0
fi

# ============================================
# Step 3: Confirm
# ============================================
if [ "$ASSUME_YES" != "yes" ]; then
    echo "Step 3: Confirm"
    echo "---------------"
    echo "⚠️  Every message, account, alias and setting in '$DB_NAME' will be"
    echo "    replaced by the contents of that file."
    if [ "$ARCHIVE_MODE" = "yes" ] && [ -s "$ARCHIVE_DIR/attachments.tar" ]; then
        echo "⚠️  Every attachment file on this install will be replaced too."
    fi
    if [ "$WITH_SECRETS" = "yes" ]; then
        echo "⚠️  SESSION_SECRET, RELAY_KEY and the VAPID keys in .env, and the"
        echo "    contents of dkim/, will be replaced by the archive's."
    fi
    echo ""
    # A typed word, not a keystroke: y is one slip away from being the answer
    # to something else, and this one is not undoable without the dump below.
    CONFIRM=""
    read -p "Type 'restore' to continue: " CONFIRM || CONFIRM=""
    if [ "$CONFIRM" != "restore" ]; then
        echo "Restore cancelled. Nothing was changed."
        exit 1
    fi
    echo ""
fi

# ============================================
# Step 4: Safety dump
# ============================================
echo "Step 4: Backing up what is there now"
echo "------------------------------------"

SAFETY_FILE=""
if [ "$TAKE_BACKUP" = "no" ]; then
    echo "⏭️  Skipped (--no-backup). This restore cannot be undone."
elif [ "$ARCHIVE_MODE" = "yes" ]; then
    # A dump alone is not a way back from an archive restore: the attachments
    # and possibly the keys are being replaced too. So the safety copy is a
    # full one, taken by the same script that made the archive rather than by a
    # second copy of its logic here.
    echo "📦 Taking a full backup of this install first..."
    if ./backup.sh --output "$BACKUP_DIR" > /dev/null 2>&1; then
        SAFETY_FILE=$(ls -t "$BACKUP_DIR"/una-backup_*.tar.gz 2>/dev/null | head -n 1 || true)
        echo "✅ Saved: $SAFETY_FILE ($(ls -lh "$SAFETY_FILE" | awk '{print $5}'))"
    else
        SAFETY_FILE=""
        echo "⚠️  Could not take a full backup."
        echo "    That is expected on a server with nothing on it yet, and a"
        echo "    problem if this one has mail on it."
        echo ""
        CONTINUE=""
        read -p "Continue without a way back? (y/N): " CONTINUE || CONTINUE=""
        if [ "$CONTINUE" != "y" ] && [ "$CONTINUE" != "Y" ]; then
            echo "Restore cancelled. Nothing was changed."
            exit 1
        fi
    fi
else
    mkdir -p "$BACKUP_DIR"
    SAFETY_FILE="$BACKUP_DIR/pre-restore_$(date +%Y%m%d_%H%M%S).sql"
    echo "📦 Dumping the current database..."
    if docker compose exec -T postgres pg_dump -U "$DB_USER" "$DB_NAME" > "$SAFETY_FILE" 2>/dev/null; then
        echo "✅ Saved: $SAFETY_FILE ($(ls -lh "$SAFETY_FILE" | awk '{print $5}'))"
    else
        rm -f "$SAFETY_FILE"
        SAFETY_FILE=""
        echo "⚠️  Could not dump the current database."
        echo "    That is expected if it is empty or already broken, and a"
        echo "    problem if it is neither."
        echo ""
        CONTINUE=""
        read -p "Continue without a way back? (y/N): " CONTINUE || CONTINUE=""
        if [ "$CONTINUE" != "y" ] && [ "$CONTINUE" != "Y" ]; then
            echo "Restore cancelled. Nothing was changed."
            exit 1
        fi
    fi
fi
echo ""

# ============================================
# Step 5: Quiesce and replace
# ============================================
echo "Step 5: Restoring"
echo "-----------------"

# Everything but PostgreSQL goes down. The web container holds a connection
# pool and the outbox scheduler writes on a timer; either would be writing
# into a database being dropped out from under it.
echo "🛑 Stopping the stack (PostgreSQL stays up)..."
docker compose down
docker compose up -d postgres
for _ in $(seq 1 60); do
    docker compose exec -T postgres pg_isready -U "$DB_USER" > /dev/null 2>&1 && break
    sleep 1
done

# A plain pg_dump contains CREATE, not DROP. Restoring it onto the existing
# database would leave every old row in place and fail on every object that
# already exists. Dropping the database is what makes this a restore rather
# than a merge. Connected to `postgres`, because you cannot drop the database
# you are connected to.
echo "🗑️  Dropping and recreating '$DB_NAME'..."
docker compose exec -T postgres psql -U "$DB_USER" -d postgres -v ON_ERROR_STOP=1 \
    -c "DROP DATABASE IF EXISTS $DB_NAME WITH (FORCE)" \
    -c "CREATE DATABASE $DB_NAME OWNER $DB_USER" > /dev/null

mkdir -p "$BACKUP_DIR"
RESTORE_LOG="$BACKUP_DIR/restore_$(date +%Y%m%d_%H%M%S).log"

echo "📥 Restoring (this is the slow part — output in $RESTORE_LOG)..."
# ON_ERROR_STOP, or psql reports success having skipped every statement that
# failed. The log is where the reason lives when it does fail; a dump of any
# size produces far too much output to put on screen.
if $READ_DUMP "$DUMP_SQL" | docker compose exec -T postgres \
        psql -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 --quiet \
        > "$RESTORE_LOG" 2>&1; then
    echo "✅ Restored"
else
    echo ""
    echo "❌ The restore failed. Last lines of $RESTORE_LOG:"
    echo ""
    tail -n 20 "$RESTORE_LOG" | sed 's/^/     /'
    echo ""
    if [ -n "$SAFETY_FILE" ]; then
        echo "   The database is now part-restored. To put back what you had:"
        echo ""
        echo "     ./restore.sh $SAFETY_FILE"
        echo ""
    else
        echo "   No safety dump was taken, so there is nothing to put back."
        echo ""
    fi
    echo "   Everything but PostgreSQL is still stopped, deliberately: the"
    echo "   database is part-restored and bringing the app up against it"
    echo "   would only add to what has to be undone."
    echo ""
    echo "   Send the log to support@una.email if the reason is not obvious."
    exit 1
fi
echo ""

# ============================================
# Step 6: Files and keys
# ============================================
if [ "$ARCHIVE_MODE" = "yes" ]; then
    echo "Step 6: Attachments and keys"
    echo "----------------------------"

    if [ -s "$ARCHIVE_DIR/attachments.tar" ]; then
        # Replace, not merge -- the same reason the database is dropped and
        # recreated. Files this install has that the archive does not are files
        # the restored rows know nothing about, and leaving them would be
        # keeping two installs' attachments in one tree.
        echo "📎 Replacing the attachments volume..."
        docker run --rm -v "$ATTACHMENTS_VOL":/data -v "$ARCHIVE_DIR":/in:ro alpine \
            sh -c 'rm -rf /data/* /data/.[!.]* 2>/dev/null; tar xf /in/attachments.tar -C /data'
        echo "✅ Attachments restored"
    else
        echo "📎 No attachments in the archive — leaving this install's alone"
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
            echo "🔑 $key restored"
        }

        for key in SESSION_SECRET RELAY_KEY VAPID_PUBLIC_KEY VAPID_PRIVATE_KEY VAPID_SUBJECT; do
            set_env_key "$key"
        done

        if [ -d "$ARCHIVE_DIR/dkim" ]; then
            find dkim -mindepth 1 ! -name '.gitkeep' -delete 2>/dev/null || true
            cp -R "$ARCHIVE_DIR/dkim/." dkim/
            echo "🔑 dkim/ restored"
        fi

        echo "📦 What those were before: $SECRETS_BACKUP"

        # A domain mismatch is not something to fix silently. The restored
        # database names the old domain in its own rows, and the two have to
        # agree or mail routes to an address this install does not serve.
        ARCHIVE_DOMAIN=$(grep -E '^[[:space:]]*DOMAIN=' "$ARCHIVE_DIR/env" | head -n 1 | cut -d= -f2- || true)
        LOCAL_DOMAIN=$(grep -E '^[[:space:]]*DOMAIN=' .env | head -n 1 | cut -d= -f2- || true)
        if [ -n "$ARCHIVE_DOMAIN" ] && [ "$ARCHIVE_DOMAIN" != "$LOCAL_DOMAIN" ]; then
            echo ""
            echo "⚠️  The archive was taken from '$ARCHIVE_DOMAIN' and this install"
            echo "    is '$LOCAL_DOMAIN'. DOMAIN was left as this install has it,"
            echo "    but the restored database still describes the old one."
            echo "    Check Settings → Domains before trusting outbound mail."
        fi
    else
        echo "🔑 Secrets left alone. If this is a move to a new server, the"
        echo "   sessions, the stored relay password, push notifications and"
        echo "   DKIM signing all depend on the old values — re-run with"
        echo "   --with-secrets."
    fi
    echo ""
fi

# ============================================
# Step 7: Bring it back up
# ============================================
echo "Step 7: Starting up"
echo "-------------------"

docker compose up -d
echo "✅ Stack started"

# A dump from an older release restores an older schema. `migrate deploy` is
# what makes it the schema this release expects, and it is a no-op when the
# dump is current.
for _ in $(seq 1 60); do
    docker compose exec -T web test -f package.json > /dev/null 2>&1 && break
    sleep 1
done

# A dump taken from a box built by `prisma db push` carries the schema and an
# empty _prisma_migrations, and `migrate deploy` refuses that with P3005. The
# same helper update.sh runs records what the database already has so deploy
# can apply the rest. It does nothing when the dump is current.
echo "🧾 Recording any migrations this database already has..."
if docker compose exec -T web test -f scripts/baseline-migrations.js 2>/dev/null; then
    if ! docker compose exec -T web node scripts/baseline-migrations.js; then
        echo "⚠️  Could not record the existing migration history."
        echo "   The migration step below will report what went wrong."
    fi
else
    echo "⚠️  This web image predates the baseline helper; skipping."
fi

echo "🗄️  Applying database migrations..."
if docker compose exec -T web npx prisma migrate deploy 2>&1; then
    echo "✅ Migrations complete"
else
    echo ""
    echo "❌ Migrations failed against the restored database."
    echo "   The data is in, but the schema is behind what this release wants."
    if [ -n "$SAFETY_FILE" ]; then
        echo "   To go back: ./restore.sh $SAFETY_FILE"
    fi
    echo "   Send the error above to support@una.email."
    exit 1
fi
echo ""

# ============================================
# Step 8: Verify
# ============================================
echo "Step 8: Verification"
echo "--------------------"

COUNTS=$(docker compose exec -T postgres psql -U "$DB_USER" -d "$DB_NAME" -tA -F' ' \
    -c "SELECT
          (SELECT count(*) FROM users),
          (SELECT count(*) FROM accounts),
          (SELECT count(*) FROM aliases),
          (SELECT count(*) FROM emails)" 2>/dev/null || true)

if [ -n "$COUNTS" ]; then
    read -r N_USERS N_ACCOUNTS N_ALIASES N_EMAILS <<< "$COUNTS"
    echo "👤 Users:     $N_USERS"
    echo "📬 Mailboxes: $N_ACCOUNTS"
    echo "🏷️  Aliases:   $N_ALIASES"
    echo "✉️  Messages:  $N_EMAILS"
else
    echo "⚠️  Could not read row counts. Check: docker compose logs postgres"
fi

echo -n "🌐 Web interface: "
sleep 5
if docker compose exec -T web wget -q -O /dev/null http://localhost:3000 > /dev/null 2>&1; then
    echo "✅ Responding"
else
    echo "⚠️  Not responding (may still be starting)"
fi
echo ""

echo "=========================================="
echo "       Restore Complete!"
echo "=========================================="
echo ""
if [ -n "$SAFETY_FILE" ]; then
    echo "📦 What you had before this is in: $SAFETY_FILE"
    echo "   (Delete it once you are happy with the restore.)"
    echo ""
fi
if [ "$ARCHIVE_MODE" = "yes" ] && [ "$WITH_SECRETS" = "yes" ]; then
    echo "🔐 The DKIM keys came across, so your existing DNS record still"
    echo "   matches. TLS did not: run ./renew-ssl.sh on this machine."
    echo ""
fi
echo "Sign in and check your mail before deleting anything."
echo ""
