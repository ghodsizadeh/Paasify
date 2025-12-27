# GitHub Deployment Guide

This guide covers setting up automated deployments from GitHub to your PaaS.

## Overview

The deployment flow:

```
Push to main → GitHub Actions → Build Docker Image → Push to Registry → SSH Deploy → Health Check
```

---

## Prerequisites

1. **Deploy user on server** (for SSH access)
2. **Docker registry** (self-hosted or ghcr.io)
3. **Application configured** in `/opt/paas/apps/myapp`

---

## Step 1: Create Deploy User

On your VPS, create a dedicated user for deployments:

```bash
# Create deploy user
sudo useradd -m -s /bin/bash deploy

# Add to docker group
sudo usermod -aG docker deploy

# Allow running deploy script
echo "deploy ALL=(ALL) NOPASSWD: /opt/paas/scripts/deploy.sh" | sudo tee /etc/sudoers.d/deploy
```

---

## Step 2: Set Up SSH Keys

### Generate SSH Key (on your local machine)

```bash
# Generate a new SSH key for GitHub Actions
ssh-keygen -t ed25519 -C "github-actions-deploy" -f ~/.ssh/github_deploy_key -N ""

# View the public key
cat ~/.ssh/github_deploy_key.pub
```

### Add Public Key to Server

```bash
# On your VPS, as root
mkdir -p /home/deploy/.ssh
nano /home/deploy/.ssh/authorized_keys
# Paste the public key

chmod 700 /home/deploy/.ssh
chmod 600 /home/deploy/.ssh/authorized_keys
chown -R deploy:deploy /home/deploy/.ssh
```

---

## Step 3: Configure GitHub Secrets

Go to your GitHub repository → **Settings** → **Secrets and variables** → **Actions**

Add these secrets:

| Secret | Description | Example |
|--------|-------------|---------|
| `VPS_HOST` | Server IP or hostname | `123.45.67.89` |
| `VPS_SSH_KEY` | Private SSH key (entire content) | `-----BEGIN OPENSSH PRIVATE KEY-----...` |
| `VPS_USER` | SSH username | `deploy` |

### For Self-Hosted Registry

If using your private registry, also add:

| Secret | Description |
|--------|-------------|
| `REGISTRY_USER` | Registry username |
| `REGISTRY_PASS` | Registry password |

---

## Step 4: Add Workflow to Repository

### Option A: Using new-app.sh (Recommended)

The `new-app.sh` script creates a customized workflow for your app:

```bash
# On your server
/opt/paas/scripts/new-app.sh myapp

# Copy the generated workflow to your local repo
scp -r deploy@yourserver:/opt/paas/apps/myapp/.github .
```

### Option B: Manual Setup

Copy and customize the template workflow:

```yaml
# .github/workflows/deploy.yml
name: Build and Deploy

on:
  push:
    branches: [main]
  workflow_dispatch:

env:
  APP_NAME: myapp
  REGISTRY: registry.yourdomain.com
  IMAGE_NAME: myapp

jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    outputs:
      version: ${{ steps.meta.outputs.version }}

    steps:
      - uses: actions/checkout@v4
      
      - uses: docker/setup-buildx-action@v3
      
      - name: Login to Registry
        uses: docker/login-action@v3
        with:
          registry: ${{ env.REGISTRY }}
          username: ${{ secrets.REGISTRY_USER }}
          password: ${{ secrets.REGISTRY_PASS }}
      
      - name: Extract metadata
        id: meta
        uses: docker/metadata-action@v5
        with:
          images: ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}
          tags: |
            type=sha,prefix=
            type=raw,value=latest
      
      - name: Build and push
        uses: docker/build-push-action@v5
        with:
          context: .
          push: true
          tags: ${{ steps.meta.outputs.tags }}
          cache-from: type=gha
          cache-to: type=gha,mode=max

  deploy:
    needs: build
    runs-on: ubuntu-latest
    
    steps:
      - name: Deploy via SSH
        uses: appleboy/ssh-action@v1.0.3
        with:
          host: ${{ secrets.VPS_HOST }}
          username: ${{ secrets.VPS_USER }}
          key: ${{ secrets.VPS_SSH_KEY }}
          script: |
            echo "${{ secrets.REGISTRY_PASS }}" | docker login ${{ env.REGISTRY }} -u "${{ secrets.REGISTRY_USER }}" --password-stdin
            /opt/paas/scripts/deploy.sh myapp ${{ needs.build.outputs.version }}
```

---

## Step 5: Create Dockerfile

Your repository needs a `Dockerfile`. Example for a Node.js app:

```dockerfile
# Build stage
FROM node:20-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build

# Production stage
FROM node:20-alpine
WORKDIR /app
COPY --from=builder /app/dist ./dist
COPY --from=builder /app/node_modules ./node_modules
COPY package*.json ./

# Health check endpoint
HEALTHCHECK --interval=30s --timeout=10s --retries=3 \
  CMD wget --no-verbose --tries=1 --spider http://localhost:3000/health || exit 1

EXPOSE 3000
CMD ["node", "dist/index.js"]
```

---

## Step 6: Test Deployment

1. Push to your `main` branch
2. Go to **Actions** tab in GitHub
3. Watch the workflow run
4. Check your app at `https://myapp.yourdomain.com`

---

## Using GitHub Container Registry (ghcr.io)

If you prefer GitHub's built-in registry:

```yaml
env:
  REGISTRY: ghcr.io
  IMAGE_NAME: ${{ github.repository }}

# ...

- name: Login to Registry
  uses: docker/login-action@v3
  with:
    registry: ${{ env.REGISTRY }}
    username: ${{ github.actor }}
    password: ${{ secrets.GITHUB_TOKEN }}  # Built-in, no secret needed
```

**Note**: For private images, you'll need to configure the server to pull from ghcr.io:

```bash
# On server, login as deploy user
echo "YOUR_GITHUB_PAT" | docker login ghcr.io -u USERNAME --password-stdin
```

---

## Workflow Triggers

### Push to Main (Default)

```yaml
on:
  push:
    branches: [main]
```

### Manual Trigger

```yaml
on:
  workflow_dispatch:
    inputs:
      environment:
        description: 'Target environment'
        required: true
        default: 'production'
        type: choice
        options:
          - production
          - staging
```

### On Release

```yaml
on:
  release:
    types: [published]
```

---

## Troubleshooting

### SSH Connection Failed

```
Error: ssh: connect to host x.x.x.x port 22: Connection timed out
```

**Solution**: 
- Verify `VPS_HOST` is correct
- Check firewall allows port 22
- Verify SSH key is correctly copied

### Registry Login Failed

```
Error: unauthorized: authentication required
```

**Solution**:
- Verify `REGISTRY_USER` and `REGISTRY_PASS` secrets
- Check user exists: `/opt/paas/scripts/registry-user.sh list`

### Deployment Timeout

```
Error: deployment failed - health check timeout
```

**Solution**:
- Verify health endpoint is responding
- Check container logs: `docker logs myapp`
- Increase timeout in docker-compose.yml

### Image Not Found

```
Error: pull access denied
```

**Solution**:
- Verify image was pushed successfully
- Check registry login on server
- For ghcr.io, ensure package visibility is correct

---

## Security Best Practices

1. **Rotate SSH keys periodically**
2. **Use separate deploy users** per environment
3. **Limit deploy user permissions** (only docker, deploy script)
4. **Review workflow files** - they can execute arbitrary code
5. **Pin action versions** - use `@v4` not `@main`
