#!/bin/bash
#===============================================================================
# PaaS Initial Setup Script
# Sets up a self-hosted PaaS on a fresh Hetzner VPS
#===============================================================================

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
PAAS_ROOT="/opt/paas"
REPO_URL="https://github.com/ghodsizadeh/Paasify.git"

# Source config file if available
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
set -a # Automatically export all variables
if [[ -f "${SCRIPT_DIR}/../config.env.local" ]]; then
    source "${SCRIPT_DIR}/../config.env.local"
elif [[ -f "${SCRIPT_DIR}/../config.env" ]]; then
    source "${SCRIPT_DIR}/../config.env"
fi
set +a

# Defaults (can be overridden by config.env)
DOMAIN="${DOMAIN:-example.com}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@example.com}"
REGISTRY_USER="${REGISTRY_USER:-admin}"
REGISTRY_PASSWORD="${REGISTRY_PASSWORD:-changeme}"

#-------------------------------------------------------------------------------
# Helper Functions
#-------------------------------------------------------------------------------

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

#-------------------------------------------------------------------------------
# Installation Functions
#-------------------------------------------------------------------------------

install_docker() {
    log_info "Installing Docker..."
    
    if command -v docker &> /dev/null; then
        log_warn "Docker is already installed, skipping..."
        return
    fi
    
    curl -fsSL https://get.docker.com | sh
    systemctl enable docker
    systemctl start docker
    
    log_success "Docker installed successfully"
}

install_git() {
    log_info "Installing Git..."
    
    if command -v git &> /dev/null; then
        log_warn "Git is already installed, skipping..."
        return
    fi
    
    apt-get update && apt-get install -y git
    log_success "Git installed successfully"
}

configure_firewall() {
    log_info "Configuring UFW firewall..."
    
    if ! command -v ufw &> /dev/null; then
        apt-get update && apt-get install -y ufw
    fi
    
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow ssh
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw --force enable
    
    log_success "Firewall configured"
}

clone_repo() {
    log_info "Cloning PaaS repository to ${PAAS_ROOT}..."

    if [[ -d "${PAAS_ROOT}/.git" ]]; then
        log_info "Repository already exists, updating..."
        cd "${PAAS_ROOT}"
        git pull
    elif [[ -d "${PAAS_ROOT}" && ! -z "$(ls -A ${PAAS_ROOT})" ]]; then
         log_warn "Directory ${PAAS_ROOT} exists and is not empty. Skipping clone."
         # In a real scenario we might want to panic here, but for now we assume the user knows what they are doing if the folder exists.
    else
        mkdir -p "${PAAS_ROOT}"
        git clone "${REPO_URL}" "${PAAS_ROOT}"
    fi

    log_success "Repository cloned"
}

create_docker_networks() {
    log_info "Creating Docker networks..."
    
    docker network create web 2>/dev/null || log_warn "Network 'web' already exists"
    docker network create internal 2>/dev/null || log_warn "Network 'internal' already exists"
    
    log_success "Docker networks ready"
}

setup_traefik() {
    log_info "Configuring Traefik..."
    
    # Create acme.json with correct permissions
    touch "${PAAS_ROOT}/traefik/acme.json"
    chmod 600 "${PAAS_ROOT}/traefik/acme.json"
    
    # Update email in traefik.yml
    if [[ -f "${PAAS_ROOT}/traefik/traefik.yml" ]]; then
        sed -i "s/email: .*$/email: ${ADMIN_EMAIL}/" "${PAAS_ROOT}/traefik/traefik.yml"
        log_success "Traefik email configured to ${ADMIN_EMAIL}"
    else
        log_error "${PAAS_ROOT}/traefik/traefik.yml not found!"
    fi

    log_success "Traefik configuration ready"
}

setup_postgres() {
    log_info "Configuring PostgreSQL..."
    
    # Initialize .env from example if it doesn't exist
    if [[ ! -f "${PAAS_ROOT}/databases/postgres/.env" ]]; then
        cp "${PAAS_ROOT}/databases/postgres/.env.example" "${PAAS_ROOT}/databases/postgres/.env"
        # We could generate a random password here, but for now we leave the example/default
        # or we can use sed to replace it if we had a random password generator.
        # Let's stick to the minimal change: just copy the file.
    fi

    log_success "PostgreSQL configuration ready"
}

setup_redis() {
    log_info "Configuring Redis..."
    
    # Initialize .env from example if it doesn't exist
    if [[ ! -f "${PAAS_ROOT}/databases/redis/.env" ]]; then
        cp "${PAAS_ROOT}/databases/redis/.env.example" "${PAAS_ROOT}/databases/redis/.env"
    fi

    log_success "Redis configuration ready"
}

setup_registry() {
    log_info "Configuring Docker Registry..."
    
    # Create auth directory if it doesn't exist (it should from clone, but just in case)
    mkdir -p "${PAAS_ROOT}/registry/auth"
    
    # Create initial htpasswd file for registry if it doesn't exist
    if [[ ! -f "${PAAS_ROOT}/registry/auth/htpasswd" ]]; then
        if command -v htpasswd &> /dev/null; then
            htpasswd -Bbn "${REGISTRY_USER}" "${REGISTRY_PASSWORD}" > "${PAAS_ROOT}/registry/auth/htpasswd"
            log_success "Registry user '${REGISTRY_USER}' created"
        else
            # Try to use the registry-user.sh script if available
            if [[ -x "${PAAS_ROOT}/scripts/registry-user.sh" ]]; then
                 "${PAAS_ROOT}/scripts/registry-user.sh" add "${REGISTRY_USER}" "${REGISTRY_PASSWORD}"
                 log_success "Registry user '${REGISTRY_USER}' created via helper script"
            else
                log_warn "htpasswd not found and registry-user.sh not executable. Creating dummy file."
                touch "${PAAS_ROOT}/registry/auth/htpasswd"
            fi
        fi
    fi
    
    log_success "Docker Registry configuration ready"
}

create_deploy_user() {
    log_info "Creating deploy user for CI/CD..."
    
    if id "deploy" &>/dev/null; then
        log_warn "Deploy user already exists, skipping..."
    else
        useradd -m -s /bin/bash deploy
        usermod -aG docker deploy
        log_success "Deploy user created and added to docker group"
    fi
    
    # Allow deploy user to run deploy script without password
    cat > /etc/sudoers.d/deploy << 'EOF'
# Allow deploy user to run PaaS scripts
deploy ALL=(ALL) NOPASSWD: /opt/paas/scripts/deploy.sh
deploy ALL=(ALL) NOPASSWD: /opt/paas/scripts/new-app.sh
EOF
    chmod 440 /etc/sudoers.d/deploy
    
    log_success "Deploy user configured for CI/CD"
}

setup_backup_scripts() {
    log_info "Configuring backup scripts..."
    
    if [[ ! -f "${PAAS_ROOT}/backups/restic-env.sh" ]]; then
        if [[ -f "${PAAS_ROOT}/backups/restic-env.sh.example" ]]; then
            cp "${PAAS_ROOT}/backups/restic-env.sh.example" "${PAAS_ROOT}/backups/restic-env.sh"
            log_info "Created restic-env.sh from example"
        fi
    fi

    # Ensure scripts are executable
    chmod +x "${PAAS_ROOT}/backups/scripts/"*.sh
    chmod +x "${PAAS_ROOT}/scripts/"*.sh
    
    log_success "Backup scripts configured"
}

setup_cron() {
    log_info "Setting up backup cron jobs..."
    
    cat > /etc/cron.d/paas-backups << 'EOF'
# PaaS Backup Jobs
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

# Database backups at 2 AM daily
0 2 * * * root /opt/paas/backups/scripts/backup-databases.sh >> /var/log/paas-backup.log 2>&1

# Volume backups at 3 AM daily
0 3 * * * root /opt/paas/backups/scripts/backup-volumes.sh >> /var/log/paas-backup.log 2>&1
EOF

    chmod 644 /etc/cron.d/paas-backups
    
    log_success "Cron jobs configured"
}

install_restic() {
    log_info "Installing Restic..."
    
    if command -v restic &> /dev/null; then
        log_warn "Restic is already installed, skipping..."
        return
    fi
    
    apt-get update && apt-get install -y restic
    
    log_success "Restic installed"
}

print_next_steps() {
    echo ""
    echo "========================================"
    echo -e "${GREEN}  PaaS Setup Complete!${NC}"
    echo "========================================"
    echo ""
    echo "Next steps:"
    echo ""
    echo "1. Configure your domain DNS to point to this server"
    echo ""
    echo "2. Update Traefik configuration with your domain:"
    echo "   # Edit ${PAAS_ROOT}/traefik/traefik.yml if needed"
    echo ""
    echo "3. Set up database passwords:"
    echo "   nano ${PAAS_ROOT}/databases/postgres/.env"
    echo "   nano ${PAAS_ROOT}/databases/redis/.env"
    echo ""
    echo "4. Configure backups:"
    echo "   nano ${PAAS_ROOT}/backups/restic-env.sh"
    echo "   restic init  # Initialize the backup repository"
    echo ""
    echo "5. Start the services:"
    echo "   cd ${PAAS_ROOT}/traefik && docker compose up -d"
    echo "   cd ${PAAS_ROOT}/registry && docker compose up -d"
    echo "   cd ${PAAS_ROOT}/databases/postgres && docker compose up -d"
    echo "   cd ${PAAS_ROOT}/databases/redis && docker compose up -d"
    echo ""
    echo "6. Manage registry users:"
    echo "   ${PAAS_ROOT}/scripts/registry-user.sh add <username>"
    echo "   ${PAAS_ROOT}/scripts/registry-user.sh list"
    echo ""
    echo "7. Deploy your first app:"
    echo "   ${PAAS_ROOT}/scripts/new-app.sh myapp  # Interactive setup"
    echo ""
    echo "8. Set up GitHub Actions deployment:"
    echo "   See ${PAAS_ROOT}/docs/GITHUB_DEPLOYMENT.md"
    echo ""
    echo "Helpful docs:"
    echo "  - ${PAAS_ROOT}/docs/DEPLOYING_APPS.md"
    echo ""
}

#-------------------------------------------------------------------------------
# Main Execution
#-------------------------------------------------------------------------------

main() {
    echo "========================================"
    echo "  PaaS Setup Script"
    echo "========================================"
    echo ""
    
    check_root
    
    install_git
    install_docker
    install_restic
    
    configure_firewall
    clone_repo        # Replaces create_directory_structure and manual file creation
    create_docker_networks
    
    setup_traefik
    setup_registry
    setup_postgres
    setup_redis
    setup_backup_scripts
    setup_cron
    setup_backup_scripts
    setup_cron
    create_deploy_user
    
    # Update/Restart services
    log_info "Starting/Updating services..."
    docker compose -f "${PAAS_ROOT}/traefik/docker-compose.yml" up -d --remove-orphans --pull always
    docker compose -f "${PAAS_ROOT}/registry/docker-compose.yml" up -d --remove-orphans --pull always
    docker compose -f "${PAAS_ROOT}/databases/postgres/docker-compose.yml" up -d --remove-orphans --pull always
    docker compose -f "${PAAS_ROOT}/databases/redis/docker-compose.yml" up -d --remove-orphans --pull always

    print_next_steps
}

main "$@"
