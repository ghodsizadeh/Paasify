#!/bin/bash
#===============================================================================
# Volume Backup Script
# Backs up Docker volumes and Traefik certificates to object storage via Restic
#
# Usage: ./backup-volumes.sh
# Cron:  0 3 * * * /opt/paas/backups/scripts/backup-volumes.sh
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAAS_ROOT="/opt/paas"
BACKUP_DIR="/tmp/volume-backups-$$"
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
echo "${LOG_PREFIX} Starting volume backup"
echo "${LOG_PREFIX} =========================================="

# ============================================================================
# Backup Traefik Certificates
# ============================================================================
if [[ -f "${PAAS_ROOT}/traefik/acme.json" ]]; then
    echo "${LOG_PREFIX} Backing up Traefik certificates..."
    cp "${PAAS_ROOT}/traefik/acme.json" "$BACKUP_DIR/acme_${TIMESTAMP}.json"
    echo "${LOG_PREFIX} Traefik certificates backed up"
else
    echo "${LOG_PREFIX} WARN: No Traefik certificates found"
fi

# ============================================================================
# Backup Configuration Files
# ============================================================================
echo "${LOG_PREFIX} Backing up configuration files..."

# Create a tarball of all docker-compose files and configs
tar czf "$BACKUP_DIR/configs_${TIMESTAMP}.tar.gz" \
    -C "${PAAS_ROOT}" \
    --exclude='*.log' \
    --exclude='acme.json' \
    --exclude='.env' \
    traefik/*.yml \
    databases/*/docker-compose.yml \
    apps/*/docker-compose.yml 2>/dev/null || true

echo "${LOG_PREFIX} Configuration files backed up"

# ============================================================================
# Backup Docker Volumes
# ============================================================================
echo "${LOG_PREFIX} Backing up Docker volumes..."

# Get list of PaaS-related volumes
VOLUMES=$(docker volume ls --format '{{.Name}}' | grep -E '^(postgres|redis|paas)' || true)

if [[ -n "$VOLUMES" ]]; then
    for volume in $VOLUMES; do
        echo "${LOG_PREFIX} Backing up volume: $volume"
        
        # Create a temporary container to access the volume and tar its contents
        docker run --rm \
            -v "$volume:/source:ro" \
            -v "$BACKUP_DIR:/backup" \
            alpine \
            tar czf "/backup/${volume}_${TIMESTAMP}.tar.gz" -C /source . 2>/dev/null || {
                echo "${LOG_PREFIX} WARN: Failed to backup volume $volume"
            }
        
        if [[ -f "$BACKUP_DIR/${volume}_${TIMESTAMP}.tar.gz" ]]; then
            SIZE=$(du -h "$BACKUP_DIR/${volume}_${TIMESTAMP}.tar.gz" | cut -f1)
            echo "${LOG_PREFIX} Volume $volume backed up (${SIZE})"
        fi
    done
else
    echo "${LOG_PREFIX} WARN: No PaaS volumes found to backup"
fi

# ============================================================================
# Upload to Object Storage
# ============================================================================
echo "${LOG_PREFIX} Uploading to object storage..."

restic backup "$BACKUP_DIR" \
    --tag volumes \
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
    --tag volumes

echo ""
echo "${LOG_PREFIX} =========================================="
echo "${LOG_PREFIX} Volume backup complete!"
echo "${LOG_PREFIX} =========================================="
