#!/bin/bash
#===============================================================================
# Disaster Recovery Script
# Restores the entire PaaS environment from Restic backups
#
# Usage: ./restore.sh [snapshot-id]
# Examples:
#   ./restore.sh           # Interactive mode, lists available snapshots
#   ./restore.sh latest    # Restore from latest snapshot
#   ./restore.sh abc123    # Restore from specific snapshot
#===============================================================================

set -euo pipefail

# Configuration
PAAS_ROOT="/opt/paas"
RESTORE_DIR="/tmp/paas-restore-$$"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${CYAN}[STEP]${NC} $1"; }

# Cleanup on exit
cleanup() {
    if [[ -d "$RESTORE_DIR" ]]; then
        rm -rf "$RESTORE_DIR"
    fi
}
trap cleanup EXIT

# ============================================================================
# Pre-flight Checks
# ============================================================================
echo ""
echo "========================================"
echo -e "${CYAN}  PaaS Disaster Recovery${NC}"
echo "========================================"
echo ""

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    log_warn "This script should be run as root for full system restore"
    read -p "Continue anyway? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Check for restic-env.sh
if [[ ! -f "${PAAS_ROOT}/backups/restic-env.sh" ]]; then
    log_error "restic-env.sh not found!"
    echo ""
    echo "To restore, you need your backup configuration."
    echo "Create ${PAAS_ROOT}/backups/restic-env.sh with your object storage credentials."
    exit 1
fi

source "${PAAS_ROOT}/backups/restic-env.sh"

# Check restic is installed
if ! command -v restic &> /dev/null; then
    log_error "Restic is not installed!"
    echo "Install with: apt-get install -y restic"
    exit 1
fi

mkdir -p "$RESTORE_DIR"

# ============================================================================
# Snapshot Selection
# ============================================================================
SNAPSHOT_ID="${1:-}"

if [[ -z "$SNAPSHOT_ID" ]]; then
    log_info "Available database snapshots:"
    echo ""
    
    # List snapshots in a readable format
    restic snapshots --tag database --json 2>/dev/null | \
        jq -r 'sort_by(.time) | reverse | .[:10][] | "\(.short_id)  \(.time | split("T")[0])  \(.tags | join(", "))"' 2>/dev/null || {
            log_error "Failed to list snapshots. Check your restic configuration."
            exit 1
        }
    
    echo ""
    read -p "Enter snapshot ID to restore (or 'latest'): " SNAPSHOT_ID
    SNAPSHOT_ID="${SNAPSHOT_ID:-latest}"
fi

echo ""
log_step "Selected snapshot: ${SNAPSHOT_ID}"

# ============================================================================
# Confirmation
# ============================================================================
echo ""
log_warn "This will restore databases from backup!"
echo ""
echo "The following will happen:"
echo "  1. Database containers will be restarted"
echo "  2. Existing data will be REPLACED with backup data"
echo "  3. Applications may experience brief downtime"
echo ""
read -p "Are you sure you want to continue? (yes/N) " CONFIRM

if [[ "$CONFIRM" != "yes" ]]; then
    echo "Aborted."
    exit 0
fi

# ============================================================================
# Restore Database Backup
# ============================================================================
echo ""
log_step "Restoring database snapshot..."

restic restore "$SNAPSHOT_ID" \
    --target "$RESTORE_DIR" \
    --tag database \
    --verbose

# Find the PostgreSQL dump
PG_DUMP=$(find "$RESTORE_DIR" -name "postgres_*.sql*" -type f 2>/dev/null | sort -r | head -1)
REDIS_DUMP=$(find "$RESTORE_DIR" -name "redis_*.rdb" -type f 2>/dev/null | sort -r | head -1)

# ============================================================================
# Restore PostgreSQL
# ============================================================================
if [[ -n "$PG_DUMP" ]]; then
    log_step "Restoring PostgreSQL from: $(basename "$PG_DUMP")"
    
    # Ensure PostgreSQL is running
    cd "${PAAS_ROOT}/databases/postgres"
    docker compose up -d --wait
    
    # Wait for PostgreSQL to be ready
    log_info "Waiting for PostgreSQL to be ready..."
    for i in {1..30}; do
        if docker exec postgres pg_isready -U admin &>/dev/null; then
            break
        fi
        sleep 1
    done
    
    # Decompress if needed
    if [[ "$PG_DUMP" == *.gz ]]; then
        log_info "Decompressing backup..."
        gunzip -k "$PG_DUMP"
        PG_DUMP="${PG_DUMP%.gz}"
    fi
    
    # Restore the database
    log_info "Restoring database (this may take a while for large databases)..."
    
    # Drop existing connections and restore
    docker exec -i postgres psql -U admin -d main << 'EOF'
SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'main' AND pid <> pg_backend_pid();
EOF

    docker exec -i postgres psql -U admin < "$PG_DUMP"
    
    log_success "PostgreSQL restored!"
else
    log_warn "No PostgreSQL dump found in snapshot"
fi

# ============================================================================
# Restore Redis
# ============================================================================
if [[ -n "$REDIS_DUMP" ]]; then
    log_step "Restoring Redis from: $(basename "$REDIS_DUMP")"
    
    # Stop Redis to replace the data file
    cd "${PAAS_ROOT}/databases/redis"
    docker compose down
    
    # Get the volume path
    REDIS_VOLUME=$(docker volume inspect redis_redis_data --format '{{.Mountpoint}}' 2>/dev/null || true)
    
    if [[ -n "$REDIS_VOLUME" ]]; then
        cp "$REDIS_DUMP" "${REDIS_VOLUME}/dump.rdb"
        chown 999:999 "${REDIS_VOLUME}/dump.rdb"
    fi
    
    # Start Redis
    docker compose up -d
    
    log_success "Redis restored!"
else
    log_warn "No Redis dump found in snapshot"
fi

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "========================================"
log_success "Recovery complete!"
echo "========================================"
echo ""
echo "Next steps:"
echo ""
echo "  1. Verify database connectivity:"
echo "     docker exec -it postgres psql -U admin -d main -c '\\dt'"
echo ""
echo "  2. Restart your applications:"
echo "     for app in ${PAAS_ROOT}/apps/*/; do"
echo "       cd \"\$app\" && docker compose up -d"
echo "     done"
echo ""
echo "  3. Verify application health:"
echo "     curl -f https://your-app.domain.com/health"
echo ""
