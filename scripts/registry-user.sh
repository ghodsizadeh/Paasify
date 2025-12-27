#!/bin/bash
#===============================================================================
# Registry User Management Script
# Manages htpasswd authentication for the Docker Registry
#
# Usage:
#   ./registry-user.sh add <username>      # Add or update a user
#   ./registry-user.sh remove <username>   # Remove a user
#   ./registry-user.sh list                # List all users
#===============================================================================

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAAS_ROOT="${SCRIPT_DIR%/scripts}"
HTPASSWD_FILE="${PAAS_ROOT}/registry/auth/htpasswd"

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

#-------------------------------------------------------------------------------
# Check Dependencies
#-------------------------------------------------------------------------------
check_htpasswd() {
    if ! command -v htpasswd &> /dev/null; then
        log_error "htpasswd is not installed."
        echo ""
        echo "Install with:"
        echo "  Ubuntu/Debian: sudo apt-get install apache2-utils"
        echo "  macOS: brew install httpd"
        echo "  Or use Docker: docker run --rm -it httpd:alpine htpasswd -Bbn user pass"
        exit 1
    fi
}

#-------------------------------------------------------------------------------
# Commands
#-------------------------------------------------------------------------------
add_user() {
    local username="$1"
    
    if [[ -z "$username" ]]; then
        log_error "Username is required"
        echo "Usage: $0 add <username>"
        exit 1
    fi
    
    check_htpasswd
    
    # Create auth directory if it doesn't exist
    mkdir -p "$(dirname "$HTPASSWD_FILE")"
    
    # Check if user exists
    if [[ -f "$HTPASSWD_FILE" ]] && grep -q "^${username}:" "$HTPASSWD_FILE"; then
        log_warn "User '${username}' already exists. Updating password..."
        htpasswd -B "$HTPASSWD_FILE" "$username"
    else
        # Create new file or add to existing
        if [[ -f "$HTPASSWD_FILE" ]]; then
            htpasswd -B "$HTPASSWD_FILE" "$username"
        else
            htpasswd -Bc "$HTPASSWD_FILE" "$username"
        fi
    fi
    
    log_success "User '${username}' has been added/updated"
    echo ""
    echo "To apply changes, restart the registry:"
    echo "  cd ${PAAS_ROOT}/registry && docker compose restart"
    echo ""
    echo "User can now login with:"
    echo "  docker login registry.yourdomain.com -u ${username}"
}

remove_user() {
    local username="$1"
    
    if [[ -z "$username" ]]; then
        log_error "Username is required"
        echo "Usage: $0 remove <username>"
        exit 1
    fi
    
    if [[ ! -f "$HTPASSWD_FILE" ]]; then
        log_error "No users exist yet"
        exit 1
    fi
    
    if ! grep -q "^${username}:" "$HTPASSWD_FILE"; then
        log_error "User '${username}' does not exist"
        exit 1
    fi
    
    # Remove user from htpasswd file
    sed -i.bak "/^${username}:/d" "$HTPASSWD_FILE"
    rm -f "${HTPASSWD_FILE}.bak"
    
    log_success "User '${username}' has been removed"
    echo ""
    echo "To apply changes, restart the registry:"
    echo "  cd ${PAAS_ROOT}/registry && docker compose restart"
}

list_users() {
    if [[ ! -f "$HTPASSWD_FILE" ]]; then
        log_warn "No users configured yet"
        echo ""
        echo "Add a user with:"
        echo "  $0 add <username>"
        exit 0
    fi
    
    echo ""
    echo "Configured registry users:"
    echo "=========================="
    while IFS=: read -r username _; do
        echo "  - $username"
    done < "$HTPASSWD_FILE"
    echo ""
}

#-------------------------------------------------------------------------------
# Main
#-------------------------------------------------------------------------------
show_usage() {
    echo "Registry User Management"
    echo ""
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  add <username>     Add or update a user (prompts for password)"
    echo "  remove <username>  Remove a user"
    echo "  list               List all configured users"
    echo ""
    echo "Examples:"
    echo "  $0 add deploy"
    echo "  $0 remove deploy"
    echo "  $0 list"
    echo ""
}

main() {
    local command="${1:-}"
    local arg="${2:-}"
    
    case "$command" in
        add)
            add_user "$arg"
            ;;
        remove)
            remove_user "$arg"
            ;;
        list)
            list_users
            ;;
        -h|--help|help)
            show_usage
            ;;
        *)
            show_usage
            exit 1
            ;;
    esac
}

main "$@"
