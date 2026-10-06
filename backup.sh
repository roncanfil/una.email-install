#!/bin/bash

# UNA.Email Backup Script
#
# Captures everything that makes this install *this install*, into one file.
#
#   ./backup.sh
#   ./backup.sh --no-compress          # attachment-heavy installs
#   ./backup.sh --output /mnt/backups
#
# What goes in, and why each one is not optional:
#
#   database.sql   The mail, the accounts, the settings.
#   attachments/   The files themselves. They live in a Docker volume and have
#                  never been in a pg_dump, so a database backup alone restores
#                  rows pointing at files that are not there.
#   env            DOMAIN and the secrets. SESSION_SECRET signs every session,
#                  RELAY_KEY decrypts the stored relay password, and VAPID_*
#                  are the identity every existing push subscription was made
#                  against. Generate new ones on the far side and you have
#                  logged everybody out, lost the relay credentials and killed
#                  every notification.
#   dkim/          The private keys your DNS publishes the public half of. Sign
#                  with a different key and outbound mail fails DMARC -- which
#                  breaks delivery without breaking anything you can see.
#
# What is deliberately left out:
#
#   TLS certificates  Re-issue on the far side with ./renew-ssl.sh. Carrying
#                     certbot's renewal state across machines causes more
#                     trouble than the two minutes it saves.
#   Bayes training    Rspamd's learned spam/ham lives in the redis_data volume.
#                     It is rebuilt by using the product, and moving Redis's
#                     on-disk state is a different job with its own failure
#                     modes. A moved install starts with the shipped rules and
#                     relearns.
#
# The result is the root of your install in one file: DKIM private keys, the
# database password, the session secret. It is written 600 and into backups/,
# which is gitignored, and you should treat a copy of it the way you would
# treat the server.

set -e
set -o pipefail

# shellcheck source=lib/ui.sh
. "$(dirname "$0")/lib/ui.sh"

DB_NAME="una_email"
DB_USER="una_email"
OUTPUT_DIR="backups"
COMPRESS="yes"

usage() {
    cat <<'USAGE'
Usage: ./backup.sh [options]

Options:
  --output DIR     Where to write the archive (default: backups/).
  --no-compress    Write a .tar instead of a .tar.gz. Faster, and no smaller
                   either way on an install whose bulk is images and PDFs.
  -h, --help       This text.
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --no-compress) COMPRESS="no" ;;
        --output)
            shift
            if [ -z "${1:-}" ]; then
                ui_fail "--output needs a directory."
                exit 1
            fi
            OUTPUT_DIR="$1"
            ;;
        -h|--help) usage; exit 0 ;;
        *)
            ui_fail "Unknown option: $1"
            echo ""
            usage
            exit 1
            ;;
    esac
    shift
done

ui_banner "Backup"

if [ ! -f .env ]; then
    ui_fail "No .env file found."
    ui_note "Run this from the directory UNA Email is installed in."
    exit 1
fi

# The volume is named after the compose project. Same derivation update.sh
# uses, including why `head -1` is not in this pipeline: under pipefail it
# SIGPIPEs sed and takes the whole script down before it prints anything.
PROJECT="$(docker compose config --format json 2>/dev/null \
    | sed -n '/"name":/{s/.*"name": *"\([^"]*\)".*/\1/p;q;}')"
if [ -z "$PROJECT" ]; then
    ui_fail "Could not read docker-compose.yml. Output:"
    docker compose config --quiet 2>&1 | ui_indent || true
    exit 1
fi
ATTACHMENTS_VOL="${PROJECT}_attachments_data"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
STAGE_DIR="$STAGE/una-backup_${TIMESTAMP}"
mkdir -p "$STAGE_DIR"

mkdir -p "$OUTPUT_DIR"

# ============================================
# Step 1: Database
# ============================================
ui_step 1 4 "Database"

if ! docker compose ps --services --filter status=running 2>/dev/null | grep -x postgres > /dev/null; then
    ui_info "PostgreSQL is not running. Starting it."
    ui_spin "Starting PostgreSQL" "PostgreSQL started" docker compose up -d postgres
    ui_wait "Waiting for PostgreSQL" "PostgreSQL ready" 60 1 \
        docker compose exec -T postgres pg_isready -U "$DB_USER" || true
fi

dump_database() {
    docker compose exec -T postgres pg_dump -U "$DB_USER" "$DB_NAME" > "$STAGE_DIR/database.sql" 2>/dev/null
}
if ! ui_spin "Dumping '$DB_NAME'" "" dump_database; then
    ui_note "Check:"
    ui_cmd "docker compose logs postgres"
    exit 1
fi
ui_ok "Database: $(ls -lh "$STAGE_DIR/database.sql" | awk '{print $5}')"

# ============================================
# Step 2: Attachments
# ============================================
ui_step 2 4 "Attachments"

if docker volume inspect "$ATTACHMENTS_VOL" > /dev/null 2>&1; then
    # Read straight from the volume rather than through the web container, so
    # this works with the stack down and does not depend on what is in the
    # image. `alpine` is already pulled on any install that has run update.sh.
    SIZE=$(docker run --rm -v "$ATTACHMENTS_VOL":/data:ro alpine \
        du -sh /data 2>/dev/null | awk '{print $1}' || echo "unknown")
    copy_attachments() {
        docker run --rm -v "$ATTACHMENTS_VOL":/data:ro -v "$STAGE_DIR":/out alpine \
            tar cf /out/attachments.tar -C /data . 2>/dev/null
    }
    ui_spin "Copying the attachments volume ($SIZE)" "" copy_attachments
    ui_ok "Attachments: $(ls -lh "$STAGE_DIR/attachments.tar" | awk '{print $5}')"
else
    # A brand new install that has never received mail has no volume yet.
    ui_warn "No attachments volume ('$ATTACHMENTS_VOL'), so nothing to copy."
    : > "$STAGE_DIR/attachments.tar"
fi

# ============================================
# Step 3: Secrets
# ============================================
ui_step 3 4 "Configuration and keys"

cp .env "$STAGE_DIR/env"
ui_ok ".env"

if [ -d dkim ] && [ -n "$(ls -A dkim 2>/dev/null | grep -v '^\.gitkeep$' || true)" ]; then
    cp -R dkim "$STAGE_DIR/dkim"
    ui_ok "dkim/ ($(ls -1 dkim | grep -vc '^\.gitkeep$' || echo 0) files)"
else
    ui_warn "dkim/ is empty. Outbound mail on the far side will need new keys"
    ui_note "and a new DNS record."
fi

# ============================================
# Step 4: Manifest and archive
# ============================================
ui_step 4 4 "Writing the archive"

# Read, never executed. It is what `restore.sh --check` prints, and what tells
# a human opening this file in a year what they are looking at.
DOMAIN_VALUE=$(grep -E '^[[:space:]]*DOMAIN=' .env | head -n 1 | cut -d= -f2- || true)
cat > "$STAGE_DIR/MANIFEST" <<MANIFEST
una.email backup
created: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
domain: ${DOMAIN_VALUE:-unknown}
host: $(hostname 2>/dev/null || echo unknown)
compose_project: $PROJECT
postgres_major: $(docker compose exec -T postgres psql -U "$DB_USER" -d postgres -tAc "SHOW server_version" 2>/dev/null | cut -d. -f1 | tr -d '[:space:]' || echo unknown)
contents: database.sql attachments.tar env dkim/
MANIFEST
ui_ok "MANIFEST"

if [ "$COMPRESS" = "yes" ]; then
    ARCHIVE="$OUTPUT_DIR/una-backup_${TIMESTAMP}.tar.gz"
    ui_spin "Compressing the archive" "" tar czf "$ARCHIVE" -C "$STAGE" "una-backup_${TIMESTAMP}"
else
    ARCHIVE="$OUTPUT_DIR/una-backup_${TIMESTAMP}.tar"
    ui_spin "Writing the archive" "" tar cf "$ARCHIVE" -C "$STAGE" "una-backup_${TIMESTAMP}"
fi

# Before anyone can read it: this file contains the DKIM private keys and every
# secret in .env.
chmod 600 "$ARCHIVE"

ui_ok "$ARCHIVE ($(ls -lh "$ARCHIVE" | awk '{print $5}'))"

ui_done "Backup complete"
ui_warn "This file holds your DKIM private keys and every secret in .env."
ui_note "It is mode 600. Copy it the way you would copy a server password,"
ui_note "and do not leave it anywhere the web server can serve it."
echo ""
ui_text "To restore it here, or on another server:"
echo ""
ui_cmd "./restore.sh $ARCHIVE --with-secrets"
echo ""
