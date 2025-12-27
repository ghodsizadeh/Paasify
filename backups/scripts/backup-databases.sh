#!/bin/bash
#===============================================================================
# Database Backup Script
# Backs up PostgreSQL and Redis to object storage via Restic
#
# Usage: ./backup-databases.sh
# Cron:  0 2 * * * /opt/paas/backups/scripts/backup-databases.sh
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="/tmp/db-backups-$$"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_PREFIX="[$(date '+%Y-%m-%d %H:%M:%S')]"

# Load Restic configuration
if [[ -f "${SCRIPT_DIR}/../restic-env.sh" ]]; then
    source "${SCRIPT_DIR}/../restic-env.sh"
else
    echo "${LOG_PREFIX} ERROR: restic-env.sh not found!"
    echo "${LOG_PREFIX} Please copy restic-env.sh.example to restic-env.sh and configure it."
    exit 1
fi

# Cleanup on exit
cleanup() {
    rm -rf "$BACKUP_DIR"
}
trap cleanup EXIT

mkdir -p "$BACKUP_DIR"

echo "${LOG_PREFIX} =========================================="
echo "${LOG_PREFIX} Starting database backup"
echo "${LOG_PREFIX} =========================================="

# ============================================================================
# PostgreSQL Backup
# ============================================================================
if docker ps --format '{{.Names}}' | grep -q '^postgres$'; then
    echo "${LOG_PREFIX} Backing up PostgreSQL..."
    
    # Get PostgreSQL user from environment or use default
    PG_USER=$(docker exec postgres printenv POSTGRES_USER 2>/dev/null || echo "admin")
    
    # Full cluster dump (all databases)
    docker exec postgres pg_dumpall -U "$PG_USER" > "$BACKUP_DIR/postgres_${TIMESTAMP}.sql"
    
    # Compress the dump
    gzip "$BACKUP_DIR/postgres_${TIMESTAMP}.sql"
    
    DUMP_SIZE=$(du -h "$BACKUP_DIR/postgres_${TIMESTAMP}.sql.gz" | cut -f1)
    echo "${LOG_PREFIX} PostgreSQL backup complete (${DUMP_SIZE})"
else
    echo "${LOG_PREFIX} WARN: PostgreSQL container not running, skipping..."
fi

# ============================================================================
# Redis Backup
# ============================================================================
if docker ps --format '{{.Names}}' | grep -q '^redis$'; then
    echo "${LOG_PREFIX} Backing up Redis..."
    
    # Get Redis password from container
    REDIS_PASS=$(docker exec redis printenv REDIS_PASSWORD 2>/dev/null || echo "changeme")
    
    # Trigger background save
    docker exec redis redis-cli --no-auth-warning -a "$REDIS_PASS" BGSAVE > /dev/null 2>&1
    
    # Wait for background save to complete
    echo "${LOG_PREFIX} Waiting for Redis BGSAVE to complete..."
    for i in {1..30}; do
        LASTSAVE=$(docker exec redis redis-cli --no-auth-warning -a "$REDIS_PASS" LASTSAVE 2>/dev/null)
        sleep 1
        NEWSAVE=$(docker exec redis redis-cli --no-auth-warning -a "$REDIS_PASS" LASTSAVE 2>/dev/null)
        if [[ "$LASTSAVE" != "$NEWSAVE" ]] || [[ $i -eq 30 ]]; then
            break
        fi
    done
    
    # Copy the RDB file
    docker cp redis:/data/dump.rdb "$BACKUP_DIR/redis_${TIMESTAMP}.rdb" 2>/dev/null || {
        echo "${LOG_PREFIX} WARN: Could not copy Redis dump file"
    }
    
    if [[ -f "$BACKUP_DIR/redis_${TIMESTAMP}.rdb" ]]; then
        DUMP_SIZE=$(du -h "$BACKUP_DIR/redis_${TIMESTAMP}.rdb" | cut -f1)
        echo "${LOG_PREFIX} Redis backup complete (${DUMP_SIZE})"
    fi
else
    echo "${LOG_PREFIX} WARN: Redis container not running, skipping..."
fi

# ============================================================================
# Upload to Object Storage
# ============================================================================
echo "${LOG_PREFIX} Uploading to object storage..."

restic backup "$BACKUP_DIR" \
    --tag database \
    --tag "$(date +%Y-%m-%d)" \
    --verbose

echo "${LOG_PREFIX} Upload complete"

# ============================================================================
# Apply Retention Policy
# ============================================================================
echo "${LOG_PREFIX} Applying retention policy..."

restic forget \
    --keep-daily 7 \
    --keep-weekly 4 \
    --keep-monthly 6 \
    --prune \
    --tag database

echo ""
echo "${LOG_PREFIX} =========================================="
echo "${LOG_PREFIX} Database backup complete!"
echo "${LOG_PREFIX} =========================================="
