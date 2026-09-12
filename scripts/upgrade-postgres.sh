#!/bin/bash

# PostgreSQL major-version upgrade for una.email
#
# Usage:
#   FROM_MAJOR=15 TO_MAJOR=18 ./scripts/upgrade-postgres.sh [--dry-run]
#
# There is no in-place major upgrade path for the official Postgres image, so
# this dumps from the running FROM_MAJOR container and restores into a fresh
# TO_MAJOR one on a NEW volume (postgres_data_${TO_MAJOR}). The original
# postgres_data volume is never written to, so rollback is just pointing
# docker-compose.yml back at it.
#
# Note the volume target changed in 18: the official image now mounts
# /var/lib/postgresql (PGDATA=/var/lib/postgresql/${TO_MAJOR}/docker) rather
# than /var/lib/postgresql/data. docker-compose.yml reflects this.
#
#   --dry-run  restore into a throwaway volume and container, verify the
#              round-trip, report row counts, then destroy both. The live
#              stack is left untouched.

set -euo pipefail

# Load .env so DB_PASSWORD matches what the rest of the stack uses. Without
# this, the ${DB_PASSWORD:-una_email_password} fallbacks below silently
# initialise the new cluster with the DEFAULT password, and every connection
# that is not covered by the image's local "trust" rules then fails auth.
# (That failure hides well: psql from inside the container over 127.0.0.1
# matches a trust rule and appears to work regardless of the password.)
ENV_FILE="$(dirname "$0")/../.env"
if [ -f "$ENV_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$ENV_FILE"
    set +a
fi

FROM_MAJOR="${FROM_MAJOR:-15}"
TO_MAJOR="${TO_MAJOR:-18}"

case "$FROM_MAJOR" in
    ''|*[!0-9]*) echo "❌ FROM_MAJOR must be an integer (got '$FROM_MAJOR')"; exit 1 ;;
esac
case "$TO_MAJOR" in
    ''|*[!0-9]*) echo "❌ TO_MAJOR must be an integer (got '$TO_MAJOR')"; exit 1 ;;
esac
if [ "$TO_MAJOR" -le "$FROM_MAJOR" ]; then
    echo "❌ TO_MAJOR ($TO_MAJOR) must be greater than FROM_MAJOR ($FROM_MAJOR)."
    exit 1
fi

OLD_CONTAINER="una-postgres"
DB_NAME="${DB_NAME:-una_email}"
DB_USER="${DB_USER:-una_email}"
NEW_IMAGE="postgres:${TO_MAJOR}-alpine"
NEW_PGDATA="/var/lib/postgresql/${TO_MAJOR}/docker"

# Compose normalises the project name (lowercases, strips dots and other
# invalid characters), so basename of the directory is not it: this repo lives
# in "una.email-install" but Compose calls the project "unaemail-install". Ask
# Compose rather than guessing, or the script populates a volume Compose never
# reads.
cd "$(dirname "$0")/.."
# `| head -1` is deliberately NOT used here: under `set -o pipefail` head exits
# after the first line, sed is killed by SIGPIPE, and the whole pipeline reports
# 141 -- which aborts this script under `set -e` before it prints anything at
# all. It races, so it looks fine on macOS and fails on Linux, which is every
# server this runs on. Let sed stop by itself instead.
PROJECT="$(docker compose config --format json 2>/dev/null \
    | sed -n '/"name":/{s/.*"name": *"\([^"]*\)".*/\1/p;q;}')"
if [ -z "$PROJECT" ]; then
    echo "❌ Could not determine the docker compose project name."
    exit 1
fi
NEW_VOLUME="${PROJECT}_postgres_data_${TO_MAJOR}"

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

if [ "$DRY_RUN" = "1" ]; then
    NEW_VOLUME="una_pg${TO_MAJOR}_dryrun_$$"
    PROBE_CONTAINER="una-pg${TO_MAJOR}-dryrun-$$"
else
    PROBE_CONTAINER="una-pg${TO_MAJOR}-restore"
fi

DUMP_DIR="$(mktemp -d)"
DUMP_FILE="$DUMP_DIR/una_email_$(date +%Y%m%d_%H%M%S).dump"

cleanup() {
    if [ "$DRY_RUN" = "1" ]; then
        echo "🧹 Cleaning up dry-run artefacts..."
        docker rm -f "$PROBE_CONTAINER" >/dev/null 2>&1 || true
        docker volume rm "$NEW_VOLUME" >/dev/null 2>&1 || true
    fi
    rm -rf "$DUMP_DIR"
}
trap cleanup EXIT

echo "🐘 PostgreSQL upgrade: ${FROM_MAJOR} -> ${TO_MAJOR}"
[ "$DRY_RUN" = "1" ] && echo "   (dry run — live stack will not be modified)"
echo

# --- 1. Preconditions -------------------------------------------------------

if ! docker ps --format '{{.Names}}' | grep -qx "$OLD_CONTAINER"; then
    echo "❌ Container '$OLD_CONTAINER' is not running. Start it first: docker compose up -d postgres"
    exit 1
fi

OLD_VERSION=$(docker exec "$OLD_CONTAINER" postgres --version | grep -oE '[0-9]+\.[0-9]+' | head -1)
RUNNING_MAJOR=$(docker exec "$OLD_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -tAc \
    "SELECT substring(version() FROM 'PostgreSQL ([0-9]+)');" | tr -d '[:space:]')
if [ "$RUNNING_MAJOR" -ge "$TO_MAJOR" ]; then
    echo "❌ Running container is already PostgreSQL $RUNNING_MAJOR; nothing to upgrade to $TO_MAJOR."
    exit 1
fi
if [ "$RUNNING_MAJOR" != "$FROM_MAJOR" ]; then
    echo "❌ Running container is PostgreSQL $RUNNING_MAJOR, but FROM_MAJOR=$FROM_MAJOR."
    echo "   Refusing to dump a cluster that is not the expected source major."
    echo "   Set FROM_MAJOR=$RUNNING_MAJOR if you intend to upgrade this cluster to $TO_MAJOR."
    exit 1
fi
echo "   Source: $OLD_CONTAINER (PostgreSQL $OLD_VERSION)"
echo "   Target: $NEW_IMAGE"
echo "   Volume: $NEW_VOLUME"
echo "   PGDATA: $NEW_PGDATA"
echo

if [ "$DRY_RUN" = "0" ] && docker volume inspect "$NEW_VOLUME" >/dev/null 2>&1; then
    echo "❌ Volume '$NEW_VOLUME' already exists. Remove it first if you mean to redo the upgrade:"
    echo "     docker volume rm $NEW_VOLUME"
    exit 1
fi

# --- 2. Dump ----------------------------------------------------------------

echo "📦 Dumping '$DB_NAME' from $OLD_CONTAINER..."
# Custom format: version-tolerant and restorable by the newer pg_restore.
docker exec "$OLD_CONTAINER" pg_dump -U "$DB_USER" -d "$DB_NAME" -Fc > "$DUMP_FILE"
echo "   Wrote $(du -h "$DUMP_FILE" | cut -f1) to $DUMP_FILE"

# Record source row counts so the restore can be checked against them.
# Exact COUNT(*) per table, not pg_stat_user_tables.n_live_tup: the latter is a
# statistics estimate that reads 0 on a database that has never been ANALYZEd.
count_tables() {
    local container="$1"
    local tables
    tables=$(docker exec "$container" psql -U "$DB_USER" -d "$DB_NAME" -tAc "
        SELECT tablename FROM pg_tables
        WHERE schemaname = 'public' ORDER BY tablename;")
    local q=""
    while IFS= read -r t; do
        [ -z "$t" ] && continue
        [ -n "$q" ] && q+=" UNION ALL "
        q+="SELECT '$t' AS t, count(*) AS n FROM \"$t\""
    done <<< "$tables"
    [ -z "$q" ] && return 0
    docker exec "$container" psql -U "$DB_USER" -d "$DB_NAME" -tAc \
        "SELECT t || '=' || n FROM ($q) s ORDER BY t;"
}

SRC_COUNTS=$(count_tables "$OLD_CONTAINER")
echo

# --- 3. Start the new server on a fresh volume ------------------------------

echo "🚀 Starting $NEW_IMAGE on volume '$NEW_VOLUME'..."
docker volume create "$NEW_VOLUME" >/dev/null
docker run -d --name "$PROBE_CONTAINER" \
    -e POSTGRES_DB="$DB_NAME" \
    -e POSTGRES_USER="$DB_USER" \
    -e POSTGRES_PASSWORD="${DB_PASSWORD:-una_email_password}" \
    -e PGDATA="$NEW_PGDATA" \
    -v "$NEW_VOLUME":/var/lib/postgresql \
    "$NEW_IMAGE" >/dev/null

# The official image's entrypoint runs a TEMPORARY server during initdb, on the
# same socket, and stops it before starting the real one. pg_isready succeeds
# against that temporary server, so waiting on pg_isready alone races the
# restart and pg_restore then fails with "No such file or directory" on the
# socket. Wait for the entrypoint to announce init is finished first, then for
# the real server to be ready, and require it to stay ready.
printf "   Waiting for initdb to finish"
for _ in $(seq 1 120); do
    if docker logs "$PROBE_CONTAINER" 2>&1 | grep -q "init process complete"; then
        break
    fi
    printf "."
    sleep 1
done
echo

printf "   Waiting for the server to accept connections"
READY=0
for _ in $(seq 1 60); do
    # three consecutive successes, so a momentary restart cannot look ready
    if docker exec "$PROBE_CONTAINER" pg_isready -U "$DB_USER" >/dev/null 2>&1 \
    && sleep 1 && docker exec "$PROBE_CONTAINER" pg_isready -U "$DB_USER" >/dev/null 2>&1 \
    && sleep 1 && docker exec "$PROBE_CONTAINER" pg_isready -U "$DB_USER" >/dev/null 2>&1; then
        READY=1
        break
    fi
    printf "."
    sleep 1
done
echo
if [ "$READY" = "0" ]; then
    echo "❌ New server never became ready. Logs:"
    docker logs "$PROBE_CONTAINER" --tail 40
    exit 1
fi

# --- 4. Restore -------------------------------------------------------------

echo "📥 Restoring into PostgreSQL ${TO_MAJOR}..."
# --clean --if-exists so the restore is idempotent over the initdb-created DB.
docker exec -i "$PROBE_CONTAINER" pg_restore \
    -U "$DB_USER" -d "$DB_NAME" --clean --if-exists --no-owner --no-privileges \
    < "$DUMP_FILE"

# --- 5. Verify --------------------------------------------------------------

echo
echo "🔍 Verifying round-trip..."
DST_COUNTS=$(count_tables "$PROBE_CONTAINER")

printf '%-28s %10s %10s\n' "TABLE" "BEFORE" "AFTER"
FAILED=0
while IFS= read -r row; do
    [ -z "$row" ] && continue
    t="${row%%=*}"; before="${row##*=}"
    after=$(echo "$DST_COUNTS" | grep "^${t}=" | cut -d= -f2)
    after="${after:-MISSING}"
    printf '%-28s %10s %10s' "$t" "$before" "$after"
    if [ "$before" = "$after" ]; then echo "  ✓"; else echo "  ✗"; FAILED=1; fi
done <<< "$SRC_COUNTS"

echo
if [ "$FAILED" = "1" ]; then
    echo "❌ Row counts differ between ${FROM_MAJOR} and ${TO_MAJOR}. Not safe to cut over."
    exit 1
fi
echo "✅ All row counts match."

# The image trusts local socket / 127.0.0.1 connections, so the checks above
# pass regardless of the role password. Prove the password actually works the
# way the app connects: over TCP, where scram-sha-256 is enforced.
if ! docker run --rm -e PGPASSWORD="${DB_PASSWORD:-una_email_password}" \
        --network container:"$PROBE_CONTAINER" "$NEW_IMAGE" \
        psql -h 127.0.0.1 -U "$DB_USER" -d "$DB_NAME" -tAc "select 1" >/dev/null 2>&1; then
    echo "⚠️  Row counts match but DB_PASSWORD does not authenticate over TCP."
    echo "   Fix the role password before cutting over:"
    echo "     docker exec -i <container> psql -U $DB_USER -d $DB_NAME -v pw=\"\$DB_PASSWORD\" <<'"'"'SQL'"'"'"
    echo "     ALTER ROLE $DB_USER WITH PASSWORD :'"'"'pw'"'"';"
    echo "     SQL"
    exit 1
fi
echo "✅ DB_PASSWORD authenticates over TCP."

if [ "$DRY_RUN" = "1" ]; then
    echo
    echo "✅ Dry run passed. The ${FROM_MAJOR} -> ${TO_MAJOR} dump/restore round-trips cleanly."
    echo "   Re-run without --dry-run to perform the real upgrade."
    exit 0
fi

# --- 6. Hand over to compose ------------------------------------------------

docker stop "$PROBE_CONTAINER" >/dev/null
docker rm "$PROBE_CONTAINER" >/dev/null

cat <<EOF

✅ Upgrade complete. Data now lives on volume '$NEW_VOLUME'.

Next steps:
  1. docker compose up -d postgres     # picks up postgres:${TO_MAJOR}-alpine
  2. Verify the app, then remove the old volume when you are confident:
       docker volume rm ${PROJECT}_postgres_data

Rollback (old data is untouched): set the postgres service in
docker-compose.yml back to

    image: postgres:${FROM_MAJOR}-alpine
    volumes:
      - postgres_data:/var/lib/postgresql/data

and run: docker compose up -d postgres
EOF
