#!/bin/bash
#===============================================================================
# New Application Setup Script
# Creates a new application from the template with proper configuration
#
# Usage:
#   ./new-app.sh <app-name>
#   ./new-app.sh myapp
#===============================================================================

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAAS_ROOT="${SCRIPT_DIR%/scripts}"

# Source config if available
if [[ -f "${PAAS_ROOT}/config.env.local" ]]; then
    source "${PAAS_ROOT}/config.env.local"
elif [[ -f "${PAAS_ROOT}/config.env" ]]; then
    source "${PAAS_ROOT}/config.env"
fi

DEFAULT_DOMAIN="${DEFAULT_DOMAIN:-example.com}"

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

#-------------------------------------------------------------------------------
# Validation
#-------------------------------------------------------------------------------
validate_app_name() {
    local name="$1"
    
    # Check if name is valid (alphanumeric and hyphens only)
    if ! [[ "$name" =~ ^[a-z0-9][a-z0-9-]*[a-z0-9]$|^[a-z0-9]$ ]]; then
        log_error "Invalid app name: '$name'"
        echo "App name must:"
        echo "  - Start and end with a letter or number"
        echo "  - Contain only lowercase letters, numbers, and hyphens"
        echo "  - Examples: myapp, my-app, app1"
        exit 1
    fi
    
    # Check if app already exists
    if [[ -d "${PAAS_ROOT}/apps/${name}" ]]; then
        log_error "App '${name}' already exists at ${PAAS_ROOT}/apps/${name}"
        exit 1
    fi
    
    # Check reserved names
    if [[ "$name" == "_template" ]]; then
        log_error "'_template' is a reserved name"
        exit 1
    fi
}

#-------------------------------------------------------------------------------
# Interactive Setup
#-------------------------------------------------------------------------------
prompt_config() {
    local app_name="$1"
    
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}                    New Application Setup                     ${CYAN}║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # App subdomain
    echo -e "${BLUE}App Domain${NC}"
    echo "  Your app will be accessible at: https://<subdomain>.${DEFAULT_DOMAIN}"
    echo "  Leave blank to use auto-generated: ${app_name}.${DEFAULT_DOMAIN}"
    read -p "  Subdomain [${app_name}]: " APP_SUBDOMAIN
    APP_SUBDOMAIN="${APP_SUBDOMAIN:-$app_name}"
    APP_HOST="${APP_SUBDOMAIN}.${DEFAULT_DOMAIN}"
    
    echo ""
    
    # App port
    echo -e "${BLUE}Application Port${NC}"
    echo "  The port your application listens on inside the container"
    read -p "  Port [3000]: " APP_PORT
    APP_PORT="${APP_PORT:-3000}"
    
    echo ""
    
    # Registry
    echo -e "${BLUE}Docker Registry${NC}"
    echo "  Where will you push your Docker images?"
    echo "  1) Self-hosted (registry.${DOMAIN})"
    echo "  2) GitHub Container Registry (ghcr.io)"
    echo "  3) Docker Hub"
    echo "  4) Custom"
    read -p "  Choice [1]: " REGISTRY_CHOICE
    REGISTRY_CHOICE="${REGISTRY_CHOICE:-1}"
    
    case "$REGISTRY_CHOICE" in
        1)
            IMAGE_REGISTRY="registry.${DEFAULT_DOMAIN}"
            IMAGE="${IMAGE_REGISTRY}/${app_name}:latest"
            ;;
        2)
            read -p "  GitHub username/org: " GITHUB_ORG
            IMAGE_REGISTRY="ghcr.io"
            IMAGE="${IMAGE_REGISTRY}/${GITHUB_ORG}/${app_name}:latest"
            ;;
        3)
            read -p "  Docker Hub username: " DOCKERHUB_USER
            IMAGE_REGISTRY="docker.io"
            IMAGE="${DOCKERHUB_USER}/${app_name}:latest"
            ;;
        4)
            read -p "  Full image name (e.g., registry.example.com/myapp:latest): " IMAGE
            IMAGE_REGISTRY="$(echo "$IMAGE" | cut -d'/' -f1)"
            ;;
        *)
            log_error "Invalid choice"
            exit 1
            ;;
    esac
    
    echo ""
    
    # Database
    echo -e "${BLUE}Database${NC}"
    echo "  Does your app need a database?"
    read -p "  Create PostgreSQL database? [Y/n]: " NEED_DB
    NEED_DB="${NEED_DB:-Y}"
    
    if [[ "$NEED_DB" =~ ^[Yy] ]]; then
        DATABASE_URL="postgres://\${POSTGRES_USER:-admin}:\${POSTGRES_PASSWORD:-changeme}@postgres:5432/${app_name}"
    else
        DATABASE_URL=""
    fi
    
    echo ""
    
    # GitHub Actions
    echo -e "${BLUE}GitHub Actions${NC}"
    echo "  Include GitHub Actions workflow for CI/CD?"
    read -p "  Include workflow? [Y/n]: " INCLUDE_GITHUB
    INCLUDE_GITHUB="${INCLUDE_GITHUB:-Y}"
    
    echo ""
}

#-------------------------------------------------------------------------------
# Create Application
#-------------------------------------------------------------------------------
create_app() {
    local app_name="$1"
    local app_dir="${PAAS_ROOT}/apps/${app_name}"
    
    log_info "Creating application '${app_name}'..."
    
    # Create directory
    mkdir -p "$app_dir"
    
    # Create docker-compose.yml
    cat > "${app_dir}/docker-compose.yml" << EOF
version: "3.9"

# ==============================================================================
# ${app_name}
# ==============================================================================
# Deployed at: https://${APP_HOST}
# Created: $(date +%Y-%m-%d)
# ==============================================================================

services:
  app:
    image: \${IMAGE:-${IMAGE}}
    container_name: ${app_name}
    restart: unless-stopped

    environment:
EOF

    if [[ -n "$DATABASE_URL" ]]; then
        cat >> "${app_dir}/docker-compose.yml" << EOF
      - DATABASE_URL=${DATABASE_URL}
      - REDIS_URL=redis://:\${REDIS_PASSWORD:-changeme}@redis:6379
EOF
    fi

    cat >> "${app_dir}/docker-compose.yml" << EOF
      # Add your app-specific environment variables here
      # - API_KEY=\${API_KEY}

    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.${app_name}.rule=Host(\`\${APP_HOST:-${APP_HOST}}\`)"
      - "traefik.http.routers.${app_name}.tls.certresolver=letsencrypt"
      - "traefik.http.routers.${app_name}.entrypoints=websecure"
      - "traefik.http.services.${app_name}.loadbalancer.server.port=\${APP_PORT:-${APP_PORT}}"

    networks:
      - web
      - internal

    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:\${APP_PORT:-${APP_PORT}}/health"]
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

    # Create .env file
    cat > "${app_dir}/.env" << EOF
# ==============================================================================
# ${app_name} Configuration
# ==============================================================================

# Application
APP_NAME=${app_name}
APP_HOST=${APP_HOST}
APP_PORT=${APP_PORT}

# Docker Image
IMAGE=${IMAGE}

# Database (uses shared PostgreSQL)
EOF

    if [[ -n "$DATABASE_URL" ]]; then
        cat >> "${app_dir}/.env" << EOF
DATABASE_URL=${DATABASE_URL}
REDIS_URL=redis://:\${REDIS_PASSWORD}@redis:6379
EOF
    fi

    cat >> "${app_dir}/.env" << EOF

# Application Secrets (add your own)
# API_KEY=
# SECRET_KEY=
EOF

    # Create GitHub workflow if requested
    if [[ "$INCLUDE_GITHUB" =~ ^[Yy] ]]; then
        mkdir -p "${app_dir}/.github/workflows"
        
        cat > "${app_dir}/.github/workflows/deploy.yml" << 'WORKFLOW_EOF'
# ==============================================================================
# Build and Deploy Workflow
# ==============================================================================
#
# REQUIRED SECRETS (set in GitHub repo → Settings → Secrets):
#   VPS_HOST       - Your server IP or hostname
#   VPS_SSH_KEY    - SSH private key for deployment
#   VPS_USER       - SSH username (default: deploy)
WORKFLOW_EOF

        if [[ "$REGISTRY_CHOICE" == "1" ]]; then
            cat >> "${app_dir}/.github/workflows/deploy.yml" << 'WORKFLOW_EOF'
#   REGISTRY_USER  - Registry username
#   REGISTRY_PASS  - Registry password
WORKFLOW_EOF
        fi

        cat >> "${app_dir}/.github/workflows/deploy.yml" << WORKFLOW_EOF
#
# ==============================================================================

name: Build and Deploy

on:
  push:
    branches: [main]
  workflow_dispatch:

env:
  APP_NAME: ${app_name}
  REGISTRY: ${IMAGE_REGISTRY}
WORKFLOW_EOF

        if [[ "$REGISTRY_CHOICE" == "2" ]]; then
            cat >> "${app_dir}/.github/workflows/deploy.yml" << 'WORKFLOW_EOF'
  IMAGE_NAME: ${{ github.repository }}
WORKFLOW_EOF
        else
            cat >> "${app_dir}/.github/workflows/deploy.yml" << WORKFLOW_EOF
  IMAGE_NAME: ${app_name}
WORKFLOW_EOF
        fi

        cat >> "${app_dir}/.github/workflows/deploy.yml" << 'WORKFLOW_EOF'

jobs:
  build:
    name: Build and Push
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write

    outputs:
      version: ${{ steps.meta.outputs.version }}

    steps:
      - name: Checkout repository
        uses: actions/checkout@v4

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Log in to Container Registry
        uses: docker/login-action@v3
        with:
          registry: ${{ env.REGISTRY }}
WORKFLOW_EOF

        if [[ "$REGISTRY_CHOICE" == "1" ]]; then
            cat >> "${app_dir}/.github/workflows/deploy.yml" << 'WORKFLOW_EOF'
          username: ${{ secrets.REGISTRY_USER }}
          password: ${{ secrets.REGISTRY_PASS }}
WORKFLOW_EOF
        elif [[ "$REGISTRY_CHOICE" == "2" ]]; then
            cat >> "${app_dir}/.github/workflows/deploy.yml" << 'WORKFLOW_EOF'
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
WORKFLOW_EOF
        fi

        cat >> "${app_dir}/.github/workflows/deploy.yml" << 'WORKFLOW_EOF'

      - name: Extract metadata
        id: meta
        uses: docker/metadata-action@v5
        with:
          images: ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}
          tags: |
            type=sha,prefix=
            type=raw,value=latest,enable=${{ github.ref == 'refs/heads/main' }}

      - name: Build and push
        uses: docker/build-push-action@v5
        with:
          context: .
          push: true
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}
          cache-from: type=gha
          cache-to: type=gha,mode=max

  deploy:
    name: Deploy to Server
    needs: build
    runs-on: ubuntu-latest
    if: github.ref == 'refs/heads/main'

    steps:
      - name: Deploy via SSH
        uses: appleboy/ssh-action@v1.0.3
        with:
          host: ${{ secrets.VPS_HOST }}
          username: ${{ secrets.VPS_USER || 'deploy' }}
          key: ${{ secrets.VPS_SSH_KEY }}
          script: |
WORKFLOW_EOF

        if [[ "$REGISTRY_CHOICE" == "1" ]]; then
            cat >> "${app_dir}/.github/workflows/deploy.yml" << 'WORKFLOW_EOF'
            # Login to private registry
            echo "${{ secrets.REGISTRY_PASS }}" | docker login ${{ env.REGISTRY }} -u "${{ secrets.REGISTRY_USER }}" --password-stdin
WORKFLOW_EOF
        fi

        cat >> "${app_dir}/.github/workflows/deploy.yml" << WORKFLOW_EOF
            # Deploy the application
            /opt/paas/scripts/deploy.sh ${app_name} \${{ needs.build.outputs.version }}

      - name: Verify deployment
        uses: appleboy/ssh-action@v1.0.3
        with:
          host: \${{ secrets.VPS_HOST }}
          username: \${{ secrets.VPS_USER || 'deploy' }}
          key: \${{ secrets.VPS_SSH_KEY }}
          script: |
            sleep 10
            curl -f https://${APP_HOST}/health || exit 1
            echo "✅ Deployment verified!"
WORKFLOW_EOF
    fi

    log_success "Application created at ${app_dir}"
}

#-------------------------------------------------------------------------------
# Print Summary
#-------------------------------------------------------------------------------
print_summary() {
    local app_name="$1"
    local app_dir="${PAAS_ROOT}/apps/${app_name}"
    
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║${NC}                    Application Created!                      ${GREEN}║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "  App Name:    ${app_name}"
    echo "  URL:         https://${APP_HOST}"
    echo "  Image:       ${IMAGE}"
    echo "  Port:        ${APP_PORT}"
    echo "  Location:    ${app_dir}"
    echo ""
    echo -e "${BLUE}Next Steps:${NC}"
    echo ""
    echo "  1. Create a Dockerfile in your project repository"
    echo ""
    echo "  2. Push your code to GitHub (if using GitHub Actions)"
    echo ""
    
    if [[ "$INCLUDE_GITHUB" =~ ^[Yy] ]]; then
        echo "  3. Configure GitHub Secrets:"
        echo "     - VPS_HOST: Your server IP"
        echo "     - VPS_SSH_KEY: SSH private key for 'deploy' user"
        echo "     - VPS_USER: deploy"
        if [[ "$REGISTRY_CHOICE" == "1" ]]; then
            echo "     - REGISTRY_USER: Registry username"
            echo "     - REGISTRY_PASS: Registry password"
        fi
        echo ""
    fi
    
    if [[ -n "$DATABASE_URL" ]]; then
        echo "  4. Create the database:"
        echo "     docker exec -it postgres createdb -U admin ${app_name}"
        echo ""
    fi
    
    echo "  Manual deployment:"
    echo "     /opt/paas/scripts/deploy.sh ${app_name}"
    echo ""
}

#-------------------------------------------------------------------------------
# Main
#-------------------------------------------------------------------------------
show_usage() {
    echo "New Application Setup"
    echo ""
    echo "Usage: $0 <app-name>"
    echo ""
    echo "Examples:"
    echo "  $0 myapp"
    echo "  $0 my-api"
    echo ""
}

main() {
    local app_name="${1:-}"
    
    if [[ -z "$app_name" || "$app_name" == "-h" || "$app_name" == "--help" ]]; then
        show_usage
        exit 0
    fi
    
    validate_app_name "$app_name"
    prompt_config "$app_name"
    create_app "$app_name"
    print_summary "$app_name"
}

main "$@"
