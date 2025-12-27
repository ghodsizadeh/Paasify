#!/bin/bash
#===============================================================================
# Zero-Downtime Deployment Script
# Deploys applications with health check validation
#
# Usage: ./deploy.sh <app-name> [tag]
# Examples:
#   ./deploy.sh myapp           # Deploy with 'latest' tag
#   ./deploy.sh myapp v1.2.3    # Deploy specific version
#===============================================================================

set -euo pipefail

# Configuration
PAAS_ROOT="/opt/paas"
DEFAULT_TAG="latest"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ============================================================================
# Parse Arguments
# ============================================================================
APP_NAME="${1:-}"
TAG="${2:-$DEFAULT_TAG}"

if [[ -z "$APP_NAME" ]]; then
    echo "Usage: $0 <app-name> [tag]"
    echo ""
    echo "Available apps:"
    for app_dir in "${PAAS_ROOT}/apps"/*/; do
        app=$(basename "$app_dir")
        if [[ "$app" != "_template" ]]; then
            echo "  - $app"
        fi
    done
    exit 1
fi

APP_DIR="${PAAS_ROOT}/apps/${APP_NAME}"

if [[ ! -d "$APP_DIR" ]]; then
    log_error "App directory not found: ${APP_DIR}"
    echo ""
    echo "To create a new app:"
    echo "  cp -r ${PAAS_ROOT}/apps/_template ${APP_DIR}"
    echo "  nano ${APP_DIR}/docker-compose.yml"
    exit 1
fi

if [[ ! -f "${APP_DIR}/docker-compose.yml" ]]; then
    log_error "docker-compose.yml not found in ${APP_DIR}"
    exit 1
fi

# ============================================================================
# Deployment
# ============================================================================
echo ""
echo "========================================"
log_info "Deploying ${APP_NAME}:${TAG}"
echo "========================================"
echo ""

cd "$APP_DIR"

# Record start time
START_TIME=$(date +%s)

# Step 1: Pull new image
log_info "Pulling image..."
TAG="$TAG" docker compose pull 2>&1 | grep -v "Pulling" || true

# Step 2: Get current container ID (for rollback if needed)
OLD_CONTAINER=$(docker compose ps -q 2>/dev/null | head -1 || true)

# Step 3: Deploy with zero-downtime
log_info "Starting deployment..."

# --no-deps: Don't recreate dependent services
# --wait: Wait for services to be healthy (if healthcheck defined)
# --wait-timeout: Maximum time to wait for healthy status
if TAG="$TAG" docker compose up -d --no-deps --wait --wait-timeout 120 2>&1; then
    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))
    
    echo ""
    log_success "Deployment complete in ${DURATION}s!"
    echo ""
    
    # Show container status
    docker compose ps
    
    # Show recent logs
    echo ""
    log_info "Recent logs:"
    docker compose logs --tail 10
else
    log_error "Deployment failed!"
    
    # Rollback if we had a previous container
    if [[ -n "$OLD_CONTAINER" ]]; then
        log_warn "Attempting rollback..."
        docker compose down
        docker start "$OLD_CONTAINER" 2>/dev/null || true
    fi
    
    exit 1
fi
