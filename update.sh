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

# Load configuration
source .env

MAIL_SUBDOMAIN="${MAIL_SUBDOMAIN:-mail}"
echo "Domain: $DOMAIN"
echo "Mail subdomain: $MAIL_SUBDOMAIN"
echo ""

# ============================================
# Step 1: Create Backup
# ============================================
echo "Step 1: Creating Backup"
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
    BACKUP_FILE=""
fi
echo ""

# ============================================
# Step 2: Pull New Images
# ============================================
echo "Step 2: Pulling Latest Images"
echo "-----------------------------"

echo "🚀 Downloading updates..."
docker compose pull

echo "✅ Images updated"
echo ""

# ============================================
# Step 3: Stop Services
# ============================================
echo "Step 3: Stopping Services"
echo "-------------------------"

echo "🛑 Stopping containers..."
docker compose down

echo "✅ Services stopped"
echo ""

# ============================================
# Step 4: Start New Services
# ============================================
echo "Step 4: Starting Updated Services"
echo "----------------------------------"

echo "🚀 Starting containers..."
docker compose up -d

echo "⏳ Waiting for services to start..."
sleep 20

echo "📋 Service status:"
docker compose ps --format "table {{.Name}}\t{{.Status}}"
echo ""

# ============================================
# Step 5: Run Migrations
# ============================================
echo "Step 5: Database Migrations"
echo "---------------------------"

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
        docker compose up -d postgres
        sleep 10
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
# Step 6: Health Check
# ============================================
echo "Step 6: Verification"
echo "--------------------"

# Check web interface
echo -n "🌐 Web interface: "
sleep 5
if docker compose exec -T web curl -sf http://localhost:3000 > /dev/null 2>&1; then
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

echo "🌐 Web Interface: https://$MAIL_SUBDOMAIN.$DOMAIN"
echo ""
echo "📋 Useful commands:"
echo "   docker compose logs -f       # View all logs"
echo "   docker compose ps            # Check service status"
echo ""
