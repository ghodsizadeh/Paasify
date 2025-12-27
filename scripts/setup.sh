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

# Source config file if available
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/../config.env.local" ]]; then
    source "${SCRIPT_DIR}/../config.env.local"
elif [[ -f "${SCRIPT_DIR}/../config.env" ]]; then
    source "${SCRIPT_DIR}/../config.env"
fi

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

create_directory_structure() {
    log_info "Creating PaaS directory structure..."
    
    mkdir -p "${PAAS_ROOT}"/{traefik,apps,databases/{postgres,redis},backups/scripts,scripts,registry/auth,docs}
    
    log_success "Directory structure created at ${PAAS_ROOT}"
}

create_docker_networks() {
    log_info "Creating Docker networks..."
    
    docker network create web 2>/dev/null || log_warn "Network 'web' already exists"
    docker network create internal 2>/dev/null || log_warn "Network 'internal' already exists"
    
    log_success "Docker networks ready"
}

setup_traefik() {
    log_info "Setting up Traefik reverse proxy..."
    
    # Create acme.json with correct permissions
    touch "${PAAS_ROOT}/traefik/acme.json"
    chmod 600 "${PAAS_ROOT}/traefik/acme.json"
    
    # Generate Traefik static config
    cat > "${PAAS_ROOT}/traefik/traefik.yml" << EOF
api:
  dashboard: true
  insecure: false

log:
  level: INFO

entryPoints:
  web:
    address: ":80"
    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https
  websecure:
    address: ":443"
    http:
      tls:
        certResolver: letsencrypt

providers:
  docker:
    exposedByDefault: false
    network: web
    watch: true

certificatesResolvers:
  letsencrypt:
    acme:
      email: ${ADMIN_EMAIL}
      storage: /acme.json
      httpChallenge:
        entryPoint: web
EOF

    # Generate Traefik docker-compose
    cat > "${PAAS_ROOT}/traefik/docker-compose.yml" << 'EOF'
version: "3.9"

services:
  traefik:
    image: traefik:v3.0
    container_name: traefik
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./traefik.yml:/etc/traefik/traefik.yml:ro
      - ./acme.json:/acme.json
    networks:
      - web
    labels:
      - "traefik.enable=true"
      # Dashboard
      - "traefik.http.routers.traefik.rule=Host(`traefik.${DOMAIN:-localhost}`)"
      - "traefik.http.routers.traefik.service=api@internal"
      - "traefik.http.routers.traefik.tls.certresolver=letsencrypt"
      - "traefik.http.routers.traefik.middlewares=traefik-auth"
      # Basic auth - default: admin/changeme (generate new with: htpasswd -nb admin yourpassword)
      - "traefik.http.middlewares.traefik-auth.basicauth.users=admin:$$apr1$$ruca84Hq$$mbjdMZBAG.KWn7vfN/SNK/"

networks:
  web:
    external: true
EOF

    log_success "Traefik configuration created"
}

setup_postgres() {
    log_info "Setting up PostgreSQL..."
    
    cat > "${PAAS_ROOT}/databases/postgres/docker-compose.yml" << 'EOF'
version: "3.9"

services:
  postgres:
    image: postgres:16-alpine
    container_name: postgres
    restart: unless-stopped
    environment:
      POSTGRES_USER: ${POSTGRES_USER:-admin}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:-changeme}
      POSTGRES_DB: ${POSTGRES_DB:-main}
    volumes:
      - postgres_data:/var/lib/postgresql/data
      - ./init:/docker-entrypoint-initdb.d:ro
    networks:
      - internal
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U $${POSTGRES_USER:-admin} -d $${POSTGRES_DB:-main}"]
      interval: 10s
      timeout: 5s
      retries: 5

volumes:
  postgres_data:

networks:
  internal:
    external: true
EOF

    # Create init directory for SQL scripts
    mkdir -p "${PAAS_ROOT}/databases/postgres/init"
    
    # Create .env template
    cat > "${PAAS_ROOT}/databases/postgres/.env.example" << 'EOF'
POSTGRES_USER=admin
POSTGRES_PASSWORD=your-secure-password-here
POSTGRES_DB=main
EOF

    log_success "PostgreSQL configuration created"
}

setup_redis() {
    log_info "Setting up Redis..."
    
    cat > "${PAAS_ROOT}/databases/redis/docker-compose.yml" << 'EOF'
version: "3.9"

services:
  redis:
    image: redis:7-alpine
    container_name: redis
    restart: unless-stopped
    command: redis-server --appendonly yes --requirepass ${REDIS_PASSWORD:-changeme}
    volumes:
      - redis_data:/data
    networks:
      - internal
    healthcheck:
      test: ["CMD", "redis-cli", "--no-auth-warning", "-a", "${REDIS_PASSWORD:-changeme}", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5

volumes:
  redis_data:

networks:
  internal:
    external: true
EOF

    # Create .env template
    cat > "${PAAS_ROOT}/databases/redis/.env.example" << 'EOF'
REDIS_PASSWORD=your-secure-password-here
EOF

    log_success "Redis configuration created"
}

setup_registry() {
    log_info "Setting up Docker Registry..."
    
    cat > "${PAAS_ROOT}/registry/docker-compose.yml" << 'EOF'
version: "3.9"

services:
  registry:
    image: registry:2
    container_name: registry
    restart: unless-stopped
    volumes:
      - registry_data:/var/lib/registry
      - ./auth:/auth:ro
    environment:
      REGISTRY_AUTH: htpasswd
      REGISTRY_AUTH_HTPASSWD_REALM: "Docker Registry"
      REGISTRY_AUTH_HTPASSWD_PATH: /auth/htpasswd
      REGISTRY_STORAGE_DELETE_ENABLED: "true"
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.registry.rule=Host(`registry.${DOMAIN:-localhost}`)"
      - "traefik.http.routers.registry.tls.certresolver=letsencrypt"
      - "traefik.http.routers.registry.entrypoints=websecure"
      - "traefik.http.services.registry.loadbalancer.server.port=5000"
    networks:
      - web
    healthcheck:
      test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:5000/v2/"]
      interval: 30s
      timeout: 10s
      retries: 3

volumes:
  registry_data:

networks:
  web:
    external: true
EOF

    # Create initial htpasswd file
    if command -v htpasswd &> /dev/null; then
        htpasswd -Bbn "${REGISTRY_USER}" "${REGISTRY_PASSWORD}" > "${PAAS_ROOT}/registry/auth/htpasswd"
        log_success "Registry user '${REGISTRY_USER}' created"
    else
        log_warn "htpasswd not found - install apache2-utils to create registry users"
        touch "${PAAS_ROOT}/registry/auth/htpasswd"
    fi
    
    log_success "Docker Registry configuration created"
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
    log_info "Setting up backup scripts..."
    
    # Restic environment template
    cat > "${PAAS_ROOT}/backups/restic-env.sh.example" << 'EOF'
# Hetzner Object Storage
export RESTIC_REPOSITORY="s3:https://fsn1.your-objectstorage.com/paas-backups"
export RESTIC_PASSWORD="your-encryption-password"
export AWS_ACCESS_KEY_ID="your-access-key"
export AWS_SECRET_ACCESS_KEY="your-secret-key"

# Alternative: Backblaze B2
# export RESTIC_REPOSITORY="b2:your-bucket-name:paas-backups"
# export B2_ACCOUNT_ID="your-account-id"
# export B2_ACCOUNT_KEY="your-account-key"
EOF

    # Database backup script
    cat > "${PAAS_ROOT}/backups/scripts/backup-databases.sh" << 'EOF'
#!/bin/bash
#===============================================================================
# Database Backup Script
# Backs up PostgreSQL and Redis to object storage via Restic
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
    exit 1
fi

cleanup() {
    rm -rf "$BACKUP_DIR"
}
trap cleanup EXIT

mkdir -p "$BACKUP_DIR"

echo "${LOG_PREFIX} Starting database backup..."

# PostgreSQL backup
if docker ps --format '{{.Names}}' | grep -q '^postgres$'; then
    echo "${LOG_PREFIX} Backing up PostgreSQL..."
    docker exec postgres pg_dumpall -U admin > "$BACKUP_DIR/postgres_${TIMESTAMP}.sql"
    echo "${LOG_PREFIX} PostgreSQL backup complete"
else
    echo "${LOG_PREFIX} PostgreSQL container not running, skipping..."
fi

# Redis backup
if docker ps --format '{{.Names}}' | grep -q '^redis$'; then
    echo "${LOG_PREFIX} Backing up Redis..."
    docker exec redis redis-cli --no-auth-warning -a "${REDIS_PASSWORD:-changeme}" BGSAVE
    sleep 5  # Wait for background save
    docker cp redis:/data/dump.rdb "$BACKUP_DIR/redis_${TIMESTAMP}.rdb" 2>/dev/null || true
    echo "${LOG_PREFIX} Redis backup complete"
else
    echo "${LOG_PREFIX} Redis container not running, skipping..."
fi

# Upload to object storage
echo "${LOG_PREFIX} Uploading to object storage..."
restic backup "$BACKUP_DIR" --tag database --tag "$(date +%Y-%m-%d)"

# Apply retention policy
echo "${LOG_PREFIX} Applying retention policy..."
restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune --tag database

echo "${LOG_PREFIX} Database backup complete!"
EOF

    chmod +x "${PAAS_ROOT}/backups/scripts/backup-databases.sh"

    # Volume backup script
    cat > "${PAAS_ROOT}/backups/scripts/backup-volumes.sh" << 'EOF'
#!/bin/bash
#===============================================================================
# Docker Volumes Backup Script
# Backs up all PaaS-related Docker volumes to object storage via Restic
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="/tmp/volume-backups-$$"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_PREFIX="[$(date '+%Y-%m-%d %H:%M:%S')]"

# Load Restic configuration
if [[ -f "${SCRIPT_DIR}/../restic-env.sh" ]]; then
    source "${SCRIPT_DIR}/../restic-env.sh"
else
    echo "${LOG_PREFIX} ERROR: restic-env.sh not found!"
    exit 1
fi

cleanup() {
    rm -rf "$BACKUP_DIR"
}
trap cleanup EXIT

mkdir -p "$BACKUP_DIR"

echo "${LOG_PREFIX} Starting volume backup..."

# Backup Traefik certificates
if [[ -f "/opt/paas/traefik/acme.json" ]]; then
    echo "${LOG_PREFIX} Backing up Traefik certificates..."
    cp /opt/paas/traefik/acme.json "$BACKUP_DIR/acme_${TIMESTAMP}.json"
fi

# Backup each named volume
for volume in $(docker volume ls --format '{{.Name}}' | grep -E '^(postgres|redis)_'); do
    echo "${LOG_PREFIX} Backing up volume: $volume"
    docker run --rm -v "$volume:/source:ro" -v "$BACKUP_DIR:/backup" \
        alpine tar czf "/backup/${volume}_${TIMESTAMP}.tar.gz" -C /source .
done

# Upload to object storage
echo "${LOG_PREFIX} Uploading to object storage..."
restic backup "$BACKUP_DIR" --tag volumes --tag "$(date +%Y-%m-%d)"

# Apply retention policy
echo "${LOG_PREFIX} Applying retention policy..."
restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune --tag volumes

echo "${LOG_PREFIX} Volume backup complete!"
EOF

    chmod +x "${PAAS_ROOT}/backups/scripts/backup-volumes.sh"

    log_success "Backup scripts created"
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

create_deploy_script() {
    log_info "Creating deployment helper script..."
    
    cat > "${PAAS_ROOT}/scripts/deploy.sh" << 'EOF'
#!/bin/bash
#===============================================================================
# Zero-Downtime Deployment Script
# Usage: ./deploy.sh <app-name> [tag]
#===============================================================================

set -euo pipefail

APP_NAME="${1:-}"
TAG="${2:-latest}"
PAAS_ROOT="/opt/paas"
APP_DIR="${PAAS_ROOT}/apps/${APP_NAME}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

if [[ -z "$APP_NAME" ]]; then
    echo -e "${RED}Usage: $0 <app-name> [tag]${NC}"
    echo "Available apps:"
    ls -1 "${PAAS_ROOT}/apps/" 2>/dev/null || echo "  (none)"
    exit 1
fi

if [[ ! -d "$APP_DIR" ]]; then
    echo -e "${RED}Error: App directory not found: ${APP_DIR}${NC}"
    exit 1
fi

echo -e "${BLUE}🚀 Deploying ${APP_NAME}:${TAG}${NC}"

cd "$APP_DIR"

# Pull new image
echo "Pulling new image..."
TAG="$TAG" docker compose pull

# Deploy with zero-downtime
# --no-deps: Don't recreate dependent services
# --wait: Wait for services to be healthy
echo "Starting deployment..."
TAG="$TAG" docker compose up -d --no-deps --wait

# Show status
echo ""
echo -e "${GREEN}✅ Deployment complete!${NC}"
docker compose ps
EOF

    chmod +x "${PAAS_ROOT}/scripts/deploy.sh"
    
    log_success "Deploy script created"
}

create_restore_script() {
    log_info "Creating disaster recovery script..."
    
    cat > "${PAAS_ROOT}/scripts/restore.sh" << 'EOF'
#!/bin/bash
#===============================================================================
# Disaster Recovery Script
# Restores the entire PaaS environment from backups
#===============================================================================

set -euo pipefail

PAAS_ROOT="/opt/paas"
RESTORE_DIR="/tmp/paas-restore-$$"

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

cleanup() {
    rm -rf "$RESTORE_DIR"
}
trap cleanup EXIT

echo "========================================"
echo "  PaaS Disaster Recovery"
echo "========================================"
echo ""

# Verify restic-env.sh exists
if [[ ! -f "${PAAS_ROOT}/backups/restic-env.sh" ]]; then
    log_error "restic-env.sh not found! Please configure backup settings first."
    exit 1
fi

source "${PAAS_ROOT}/backups/restic-env.sh"

mkdir -p "$RESTORE_DIR"

# List available snapshots
log_info "Available database snapshots:"
restic snapshots --tag database --json | jq -r '.[] | "\(.short_id) - \(.time) - \(.tags | join(", "))"' | head -10

echo ""
read -p "Enter snapshot ID to restore (or 'latest'): " SNAPSHOT_ID
SNAPSHOT_ID="${SNAPSHOT_ID:-latest}"

# Restore database backup
log_info "Restoring database snapshot: ${SNAPSHOT_ID}..."
restic restore "$SNAPSHOT_ID" --target "$RESTORE_DIR" --tag database

# Find the PostgreSQL dump
PG_DUMP=$(find "$RESTORE_DIR" -name "postgres_*.sql" -type f | sort -r | head -1)

if [[ -z "$PG_DUMP" ]]; then
    log_error "No PostgreSQL dump found in snapshot!"
    exit 1
fi

log_info "Found PostgreSQL dump: $(basename "$PG_DUMP")"

# Ensure PostgreSQL is running
log_info "Starting PostgreSQL..."
cd "${PAAS_ROOT}/databases/postgres"
docker compose up -d --wait

# Wait for PostgreSQL to be ready
sleep 5

# Restore the database
log_info "Restoring database..."
docker exec -i postgres psql -U admin < "$PG_DUMP"

log_success "Database restored successfully!"

# Restore Redis if available
REDIS_DUMP=$(find "$RESTORE_DIR" -name "redis_*.rdb" -type f | sort -r | head -1)
if [[ -n "$REDIS_DUMP" ]]; then
    log_info "Restoring Redis..."
    docker compose -f "${PAAS_ROOT}/databases/redis/docker-compose.yml" down
    docker cp "$REDIS_DUMP" redis:/data/dump.rdb
    docker compose -f "${PAAS_ROOT}/databases/redis/docker-compose.yml" up -d
    log_success "Redis restored!"
fi

echo ""
echo "========================================"
log_success "Recovery complete!"
echo "========================================"
echo ""
echo "Next steps:"
echo "  1. Start your applications: cd /opt/paas/apps/<app> && docker compose up -d"
echo "  2. Verify everything is working"
echo ""
EOF

    chmod +x "${PAAS_ROOT}/scripts/restore.sh"
    
    log_success "Restore script created"
}

create_app_template() {
    log_info "Creating example application template..."
    
    mkdir -p "${PAAS_ROOT}/apps/_template"
    
    cat > "${PAAS_ROOT}/apps/_template/docker-compose.yml" << 'EOF'
version: "3.9"

# ==============================================================================
# Application Template
# Copy this directory to create a new app: cp -r _template myapp
# Then customize the values below
# ==============================================================================

services:
  app:
    image: ${IMAGE:-nginx:alpine}  # Replace with your app image
    container_name: ${APP_NAME:-myapp}
    restart: unless-stopped
    environment:
      # Add your environment variables here
      - DATABASE_URL=postgres://admin:password@postgres:5432/myapp
      - REDIS_URL=redis://:password@redis:6379
    labels:
      - "traefik.enable=true"
      # Replace 'myapp' and 'example.com' with your values
      - "traefik.http.routers.${APP_NAME:-myapp}.rule=Host(`${APP_NAME:-myapp}.${DOMAIN:-example.com}`)"
      - "traefik.http.routers.${APP_NAME:-myapp}.tls.certresolver=letsencrypt"
      - "traefik.http.services.${APP_NAME:-myapp}.loadbalancer.server.port=${APP_PORT:-80}"
    networks:
      - web
      - internal
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:${APP_PORT:-80}/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s

networks:
  web:
    external: true
  internal:
    external: true
EOF

    cat > "${PAAS_ROOT}/apps/_template/.env.example" << 'EOF'
# Application Configuration
APP_NAME=myapp
DOMAIN=example.com
IMAGE=your-registry.com/your-app:latest
APP_PORT=3000

# Database connection
DATABASE_URL=postgres://admin:password@postgres:5432/myapp
REDIS_URL=redis://:password@redis:6379
EOF

    log_success "Application template created at ${PAAS_ROOT}/apps/_template"
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
    echo "   export DOMAIN=yourdomain.com"
    echo "   export ADMIN_EMAIL=admin@yourdomain.com"
    echo "   # Then re-run this script or manually update traefik.yml"
    echo ""
    echo "3. Set up database passwords:"
    echo "   cp ${PAAS_ROOT}/databases/postgres/.env.example ${PAAS_ROOT}/databases/postgres/.env"
    echo "   cp ${PAAS_ROOT}/databases/redis/.env.example ${PAAS_ROOT}/databases/redis/.env"
    echo "   # Edit both .env files with secure passwords"
    echo ""
    echo "4. Configure backups:"
    echo "   cp ${PAAS_ROOT}/backups/restic-env.sh.example ${PAAS_ROOT}/backups/restic-env.sh"
    echo "   # Edit with your object storage credentials"
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
    echo "   # Or manually:"
    echo "   cp -r ${PAAS_ROOT}/apps/_template ${PAAS_ROOT}/apps/myapp"
    echo "   ${PAAS_ROOT}/scripts/deploy.sh myapp"
    echo ""
    echo "8. Set up GitHub Actions deployment:"
    echo "   See ${PAAS_ROOT}/docs/GITHUB_DEPLOYMENT.md"
    echo ""
    echo "Useful commands:"
    echo "  - Create new app:   ${PAAS_ROOT}/scripts/new-app.sh <app-name>"
    echo "  - Deploy an app:    ${PAAS_ROOT}/scripts/deploy.sh <app-name> [tag]"
    echo "  - Registry users:   ${PAAS_ROOT}/scripts/registry-user.sh <add|remove|list>"
    echo "  - Backup databases: ${PAAS_ROOT}/backups/scripts/backup-databases.sh"
    echo "  - Restore system:   ${PAAS_ROOT}/scripts/restore.sh"
    echo ""
    echo "Documentation:"
    echo "  - Deploying Apps:   ${PAAS_ROOT}/docs/DEPLOYING_APPS.md"
    echo "  - GitHub CI/CD:     ${PAAS_ROOT}/docs/GITHUB_DEPLOYMENT.md"
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
    
    install_docker
    configure_firewall
    create_directory_structure
    create_docker_networks
    setup_traefik
    setup_registry
    setup_postgres
    setup_redis
    install_restic
    setup_backup_scripts
    setup_cron
    create_deploy_script
    create_restore_script
    create_app_template
    create_deploy_user
    
    print_next_steps
}

main "$@"
