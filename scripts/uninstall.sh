#!/bin/bash
#===============================================================================
# PaaS Uninstall Script
# WARNING: This script can delete all data and configuration!
#===============================================================================

set -euo pipefail

# Configuration
PAAS_ROOT="/opt/paas"
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Flags
FULL_CLEANUP=false

# Check for flags
for arg in "$@"; do
    if [[ "$arg" == "--full" ]]; then
        FULL_CLEANUP=true
    fi
done

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

confirm_action() {
    local message="$1"
    if [[ "$FULL_CLEANUP" == "true" ]]; then
        return 0
    fi
    
    echo -ne "${YELLOW}${message} [y/N]${NC} "
    read -r response
    if [[ "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
        return 0
    else
        return 1
    fi
}

stop_containers() {
    log_info "Stopping all containers..."
    
    # List of component directories
    local components=("traefik" "registry" "databases/postgres" "databases/redis")
    
    # Add apps
    if [[ -d "${PAAS_ROOT}/apps" ]]; then
        for app in "${PAAS_ROOT}/apps"/*; do
            if [[ -d "$app" && -f "$app/docker-compose.yml" ]]; then
                components+=("apps/$(basename "$app")")
            fi
        done
    fi

    for component in "${components[@]}"; do
        if [[ -f "${PAAS_ROOT}/${component}/docker-compose.yml" ]]; then
            log_info "Stopping ${component}..."
            cd "${PAAS_ROOT}/${component}"
            if docker compose ps --services --filter "status=running" | grep -q .; then
                 docker compose down
            else
                 log_info "${component} not running."
            fi
        fi
    done
    
    log_info "All managed containers stopped."
}

remove_volumes() {
    if confirm_action "Do you want to PERMANENTLY DELETE all docker volumes (database data, etc)?"; then
        log_warn "Deleting volumes..."
        # Prune only anonymous volumes associated with the projects? 
        # Better to be explicit if we can, but 'docker volume prune' is safer than `rm -rf`.
        # However, we want to remove named volumes postgres_data etc.
        
        # We'll use docker compose down -v inside the dirs if we want to be clean, 
        # but we already downed them.
        
        # Let's forcefully remove volumes matching our naming convention if we can find them,
        # or just suggest the user run `docker volume prune`.
        
        # Re-running down with -v is safer.
        local components=("traefik" "registry" "databases/postgres" "databases/redis")
        if [[ -d "${PAAS_ROOT}/apps" ]]; then
            for app in "${PAAS_ROOT}/apps"/*; do
                 if [[ -d "$app" && -f "$app/docker-compose.yml" ]]; then
                    components+=("apps/$(basename "$app")")
                fi
            done
        fi

        for component in "${components[@]}"; do
             if [[ -f "${PAAS_ROOT}/${component}/docker-compose.yml" ]]; then
                cd "${PAAS_ROOT}/${component}"
                docker compose down -v || true
            fi
        done
        
        log_info "Volumes removed."
    else
        log_info "Skipping volume removal."
    fi
}

remove_paas_root() {
    if confirm_action "Do you want to DELETE ${PAAS_ROOT} and all configuration files?"; then
        log_warn "Removing ${PAAS_ROOT}..."
        rm -rf "${PAAS_ROOT}"
        log_info "Directory removed."
    else
        log_info "Skipping ${PAAS_ROOT} removal."
    fi
}

remove_system_configs() {
    log_info "Removing system configurations..."
    
    rm -f /etc/cron.d/paas-backups
    rm -f /etc/sudoers.d/deploy
    
    # Remove logs if any
    rm -f /var/log/paas-backup.log
    
    log_info "System configurations removed."
}

remove_networks() {
    log_info "Removing networks..."
    docker network rm web internal 2>/dev/null || true
}

main() {
    echo "========================================"
    echo "  PaaS Uninstall Script"
    echo "========================================"
    echo ""
    log_warn "This will stop services and potentially delete data."
    echo ""
    
    if ! confirm_action "Are you sure you want to proceed?"; then
        echo "Aborted."
        exit 0
    fi
    
    check_root
    stop_containers
    remove_volumes
    remove_system_configs
    remove_networks
    remove_paas_root
    
    echo ""
    echo "========================================"
    log_info "Uninstall complete."
    echo "========================================"
}

main "$@"
