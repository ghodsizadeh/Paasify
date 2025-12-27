# Self-Hosted PaaS on Hetzner VPS

A minimal, production-ready Platform as a Service built on Docker Compose and Traefik.

## 🎯 Design Philosophy

- **Extreme Simplicity**: Docker Compose only—one tool, one file format
- **Zero Lock-in**: Standard Docker containers, portable anywhere
- **Production Ready**: SSL, health checks, automated backups out of the box
- **Easy Scaling**: Seamless migration path to Docker Swarm when needed

## 📁 Directory Structure

```
/opt/paas/
├── traefik/                  # Reverse proxy & SSL
│   ├── docker-compose.yml
│   ├── traefik.yml
│   └── acme.json
├── apps/                     # Your applications
│   ├── _template/            # Copy this for new apps
│   └── your-app/
├── databases/                # Shared databases
│   ├── postgres/
│   └── redis/
├── backups/                  # Backup configuration
│   ├── scripts/
│   └── restic-env.sh
└── scripts/                  # Helper scripts
    ├── setup.sh
    ├── deploy.sh
    └── restore.sh
```

## 🚀 Quick Start

### 1. Initial Setup

```bash
# On a fresh Hetzner VPS (Ubuntu 22.04 recommended)
curl -fsSL https://raw.githubusercontent.com/yourorg/paas/main/scripts/setup.sh | sudo bash

# Or if you have the files locally:
sudo ./scripts/setup.sh
```

### 2. Configure Your Domain

Point your DNS to the VPS IP:
```
*.yourdomain.com → YOUR_VPS_IP
```

Update Traefik with your email for Let's Encrypt:
```bash
# Edit /opt/paas/traefik/traefik.yml
# Change: email: admin@yourdomain.com
```

### 3. Set Up Databases

```bash
# Configure PostgreSQL
cp /opt/paas/databases/postgres/.env.example /opt/paas/databases/postgres/.env
nano /opt/paas/databases/postgres/.env  # Set secure password

# Configure Redis
cp /opt/paas/databases/redis/.env.example /opt/paas/databases/redis/.env
nano /opt/paas/databases/redis/.env  # Set secure password

# Start databases
cd /opt/paas/databases/postgres && docker compose up -d
cd /opt/paas/databases/redis && docker compose up -d
```

### 4. Start Traefik

```bash
cd /opt/paas/traefik && docker compose up -d

# Verify it's running
docker compose logs -f
```

### 5. Deploy Your First App

```bash
# Create from template
cp -r /opt/paas/apps/_template /opt/paas/apps/hello

# Edit the configuration
nano /opt/paas/apps/hello/docker-compose.yml

# Deploy
/opt/paas/scripts/deploy.sh hello
```

## 📦 Deploying Applications

### Using the Deploy Script

```bash
# Deploy latest tag
/opt/paas/scripts/deploy.sh myapp

# Deploy specific version
/opt/paas/scripts/deploy.sh myapp v1.2.3
```

### Docker Compose Labels for Traefik

Every app needs these labels to be exposed via Traefik:

```yaml
labels:
  - "traefik.enable=true"
  - "traefik.http.routers.myapp.rule=Host(`myapp.yourdomain.com`)"
  - "traefik.http.routers.myapp.tls.certresolver=letsencrypt"
  - "traefik.http.services.myapp.loadbalancer.server.port=3000"
```

### Zero-Downtime Requirements

For zero-downtime deployments, your app needs:

1. **Health check endpoint** (e.g., `/health`)
2. **Graceful shutdown handling** (respond to SIGTERM)
3. **Fast startup time** (< 30 seconds ideally)

## 💾 Backup & Recovery

### Configure Backups

```bash
# Set up object storage credentials
cp /opt/paas/backups/restic-env.sh.example /opt/paas/backups/restic-env.sh
nano /opt/paas/backups/restic-env.sh

# Initialize the backup repository
source /opt/paas/backups/restic-env.sh
restic init
```

### Manual Backup

```bash
# Backup databases
/opt/paas/backups/scripts/backup-databases.sh

# Backup volumes
/opt/paas/backups/scripts/backup-volumes.sh
```

### Restore from Backup

```bash
/opt/paas/scripts/restore.sh
```

### Backup Schedule (Automatic)

Backups run automatically via cron:
- **2:00 AM** - Database backups (pg_dump + Redis)
- **3:00 AM** - Volume backups (including Traefik certs)

Retention policy:
- 7 daily backups
- 4 weekly backups
- 6 monthly backups

## 🔐 Security

### Firewall (UFW)

The setup script configures:
```bash
ufw default deny incoming
ufw allow ssh
ufw allow 80/tcp
ufw allow 443/tcp
```

### Traefik Dashboard

Access at `https://traefik.yourdomain.com`

Default credentials: `admin` / `changeme`

Generate new password:
```bash
htpasswd -nb admin your-secure-password
# Update the hash in traefik/docker-compose.yml
```

### Database Access

Databases are on the `internal` network only—not exposed to the internet.

Apps connect via Docker networking:
```
postgres://user:pass@postgres:5432/dbname
redis://:password@redis:6379
```

## 🔄 Scaling to Multi-Node

When you outgrow a single server:

```bash
# On manager node
docker swarm init --advertise-addr <MANAGER_IP>

# On worker nodes
docker swarm join --token <TOKEN> <MANAGER_IP>:2377

# Deploy as stack (same compose files!)
docker stack deploy -c docker-compose.yml myapp
```

## 📊 Monitoring (Optional)

For basic monitoring, add a health check endpoint:

```bash
# Check all containers
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

# Check specific app health
curl -f https://myapp.yourdomain.com/health
```

For full observability, consider adding:
- **Prometheus** + **Grafana** for metrics
- **Loki** for log aggregation
- **Uptime Kuma** for uptime monitoring

## 🆘 Troubleshooting

### Traefik not getting SSL certificates

```bash
# Check Traefik logs
docker logs traefik

# Verify DNS is pointing to your server
dig myapp.yourdomain.com

# Check acme.json permissions
ls -la /opt/paas/traefik/acme.json  # Should be 600
```

### App not accessible

```bash
# Check if app is running
docker compose ps

# Check if app is on the web network
docker network inspect web

# Check Traefik can see the app
curl http://localhost:8080/api/http/routers  # If dashboard enabled
```

### Database connection issues

```bash
# Test from within a container
docker exec -it myapp ping postgres

# Check database is running
docker compose -f /opt/paas/databases/postgres/docker-compose.yml ps
```

## 📝 License

MIT License - Use freely for personal and commercial projects.
