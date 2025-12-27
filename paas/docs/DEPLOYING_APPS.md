# Deploying Applications

This guide covers how to deploy applications to your PaaS environment.

## Quick Start

### Using the Interactive Script

The easiest way to create a new application:

```bash
./scripts/new-app.sh myapp
```

This interactive script will:
1. Ask for your app's subdomain and port
2. Configure the Docker registry (self-hosted, ghcr.io, or Docker Hub)
3. Set up database connections
4. Create a GitHub Actions workflow (optional)

---

## Manual Deployment

### 1. Create Application from Template

```bash
# Copy the template
cp -r /opt/paas/apps/_template /opt/paas/apps/myapp
cd /opt/paas/apps/myapp

# Configure environment
cp .env.example .env
nano .env
```

### 2. Configure `.env`

```bash
# Application
APP_NAME=myapp
APP_HOST=myapp.yourdomain.com
APP_PORT=3000

# Docker Image
IMAGE=registry.yourdomain.com/myapp:latest

# Database (optional)
DATABASE_URL=postgres://admin:password@postgres:5432/myapp
```

### 3. Create Database (if needed)

```bash
# Create a new database for your app
docker exec -it postgres createdb -U admin myapp

# Or run migrations from your app
docker exec -it myapp npm run migrate
```

### 4. Deploy

```bash
# Deploy latest version
/opt/paas/scripts/deploy.sh myapp

# Deploy specific tag
/opt/paas/scripts/deploy.sh myapp v1.2.3
```

---

## Building and Pushing Images

### Using Self-Hosted Registry

```bash
# Login to registry
docker login registry.yourdomain.com -u admin

# Build your image
docker build -t registry.yourdomain.com/myapp:latest .

# Push to registry
docker push registry.yourdomain.com/myapp:latest
```

### Using GitHub Container Registry

```bash
# Login with personal access token
echo $GITHUB_TOKEN | docker login ghcr.io -u USERNAME --password-stdin

# Build and push
docker build -t ghcr.io/username/myapp:latest .
docker push ghcr.io/username/myapp:latest
```

---

## GitHub Actions Deployment

For automated deployments on every push, see [GITHUB_DEPLOYMENT.md](./GITHUB_DEPLOYMENT.md).

### Quick Setup

1. **Copy workflow to your repo**:
   ```bash
   cp /opt/paas/apps/myapp/.github/workflows/deploy.yml your-repo/.github/workflows/
   ```

2. **Add GitHub Secrets**:
   - `VPS_HOST` - Your server IP
   - `VPS_SSH_KEY` - SSH private key
   - `VPS_USER` - SSH username (usually `deploy`)
   - `REGISTRY_USER` - Registry username (for self-hosted)
   - `REGISTRY_PASS` - Registry password (for self-hosted)

3. **Push to main branch** - Deployment triggers automatically

---

## Health Checks

Your application **must** have a health check endpoint for zero-downtime deployments:

```javascript
// Express.js example
app.get('/health', (req, res) => {
  res.status(200).json({ status: 'ok' });
});
```

```python
# FastAPI example
@app.get("/health")
def health():
    return {"status": "ok"}
```

The deploy script waits for the health check to pass before considering the deployment successful.

---

## Environment Variables

### Available at Runtime

These environment variables are available inside your container:

| Variable | Description | Example |
|----------|-------------|---------|
| `DATABASE_URL` | PostgreSQL connection string | `postgres://admin:pass@postgres:5432/myapp` |
| `REDIS_URL` | Redis connection string | `redis://:pass@redis:6379` |
| Custom variables | Defined in your `.env` | Any value |

### Connecting to Databases

Your app connects to shared databases via Docker's internal network:

```yaml
# docker-compose.yml
environment:
  - DATABASE_URL=postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres:5432/myapp
  - REDIS_URL=redis://:${REDIS_PASSWORD}@redis:6379
```

---

## Troubleshooting

### Deployment fails immediately

```bash
# Check container logs
docker logs myapp

# Check if image exists
docker images | grep myapp
```

### App not accessible

```bash
# Verify container is running
docker ps | grep myapp

# Check Traefik can see it
docker logs traefik | grep myapp

# Verify network connectivity
docker network inspect web | grep myapp
```

### Health check failing

```bash
# Test health endpoint from inside container
docker exec myapp curl -f http://localhost:3000/health

# Check if port is correct
docker exec myapp netstat -tlnp
```

### SSL certificate issues

```bash
# Check Traefik certificate logs
docker logs traefik | grep -i acme

# Verify DNS is pointing to server
dig myapp.yourdomain.com
```

---

## Rollback

If a deployment fails, the previous container is automatically restarted.

For manual rollback:

```bash
# List available image tags
docker images registry.yourdomain.com/myapp

# Deploy previous version
/opt/paas/scripts/deploy.sh myapp v1.2.2
```
