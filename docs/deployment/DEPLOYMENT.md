# Production Deployment Guide

This guide covers advanced deployment topics for Mydia. For basic deployment instructions, see the [Production Deployment](../../README.md#-production-deployment) section in the main README.

## Quick Reference

**Basic deployment steps:**
1. See [README.md](../../README.md#-production-deployment) for quick start with Docker Compose or Docker Run
2. Review the [Environment Variables Reference](../../README.md#-environment-variables-reference) for all configuration options
3. Return to this guide for advanced topics below

## Installation Options

### Option 1: Pre-built Images (Recommended)

Pull the latest pre-built image from GitHub Container Registry:

```bash
docker pull ghcr.io/arsfeld/mydia:latest
```

Or pull a specific version:

```bash
docker pull ghcr.io/arsfeld/mydia:v1.0.0
```

### Option 2: Build from Source

Build the image locally from the repository:

```bash
docker build -t mydia:latest -f Dockerfile .
```

## Configuration Options

### Using Environment Files (Optional)

While the README shows inline configuration, you can optionally use a `.env` file:

1. Create a `.env.prod` file with your configuration:

```bash
# Container configuration (LinuxServer.io standards)
PUID=1000
PGID=1000
TZ=America/New_York

# Required secrets (generate with: openssl rand -base64 48)
SECRET_KEY_BASE=your-secret-key-base-here
GUARDIAN_SECRET_KEY=your-guardian-secret-key-here

# Server configuration
PHX_HOST=mydia.example.com
PORT=4000
DATABASE_PATH=/config/mydia.db

# Media paths
MOVIES_PATH=/media/movies
TV_PATH=/media/tv

# Optional: OIDC authentication
OIDC_DISCOVERY_DOCUMENT_URI=https://auth.example.com/.well-known/openid-configuration
OIDC_CLIENT_ID=your-client-id
OIDC_CLIENT_SECRET=your-client-secret
```

2. Reference it in your docker-compose.yml:

```yaml
services:
  mydia:
    image: ghcr.io/arsfeld/mydia:latest
    env_file: .env.prod
    # ... rest of configuration
```

Or with Docker Run:

```bash
docker run -d \
  --name mydia \
  --env-file .env.prod \
  -v /path/to/mydia/config:/config \
  -v /path/to/movies:/media/movies \
  -v /path/to/tv:/media/tv \
  ghcr.io/arsfeld/mydia:latest
```

See the [Environment Variables Reference](../../README.md#-environment-variables-reference) for all available options.

## Health Check

The application includes a health check endpoint at `/health` that returns JSON:

```bash
curl http://localhost:4000/health
```

Response:
```json
{
  "status": "ok",
  "service": "mydia",
  "timestamp": "2025-11-05T00:00:00Z"
}
```

## Advanced Configuration

For a complete list of all configuration options, see the [Environment Variables Reference](../../README.md#-environment-variables-reference) in the README.

Advanced topics include:
- Download client integration (qBittorrent, Transmission)
- Indexer configuration (Prowlarr, Jackett)
- Database performance tuning
- Background job configuration
- Custom logging levels

## Volumes

The production setup uses the following volumes:

- `mydia_data` - Application data and SQLite database
- Media directories - Mount your existing media library directories

## Ports

- `4000` - HTTP port for the web interface

## First Run

On first startup, the application will:
1. Run database migrations
2. Create default quality profiles
3. Start the web server on port 4000

## Troubleshooting

### Container won't start

Check the logs:
```bash
docker logs mydia
```

### Health check failing

Ensure the application is listening on the correct port:
```bash
docker exec mydia curl -f http://localhost:4000/health
```

### Database permission issues

Ensure the data volume has correct permissions:
```bash
docker exec mydia ls -la /data
```

## Upgrading

To upgrade to a new version:

1. Pull the new image
2. Stop the current container
3. Start a new container with the new image

Migrations will run automatically on startup.

### With Docker Compose

```bash
docker compose pull
docker compose down
docker compose up -d
```

### With Docker Run

```bash
docker pull ghcr.io/arsfeld/mydia:latest
docker stop mydia && docker rm mydia
# Re-run your docker run command
```

To upgrade to a specific version, specify the version tag:

```bash
docker pull ghcr.io/arsfeld/mydia:v1.0.0
# Update your docker-compose.yml or docker run command to use the specific version
```

## Release Process

Mydia uses automated CI/CD to build and publish Docker images.

### For Maintainers: Creating a Release

To create a new release:

1. Update version numbers if needed (in mix.exs, etc.)
2. Commit all changes
3. Create and push a version tag:

```bash
git tag v1.0.0
git push origin v1.0.0
```

4. GitHub Actions will automatically:
   - Build multi-platform Docker images (amd64, arm64)
   - Tag the image with the version number and 'latest'
   - Publish to GitHub Container Registry
   - Generate build attestation for supply chain security

5. Monitor the workflow at: https://github.com/arsfeld/mydia/actions

### Available Image Tags

Images are published to `ghcr.io/arsfeld/mydia` with the following tags:

- `latest` - Most recent stable release
- `v1.0.0` - Specific version (full semver)
- `v1.0` - Minor version (receives patch updates)
- `v1` - Major version (receives minor and patch updates)

### Image Platforms

All images support multiple platforms:
- `linux/amd64` - Standard x86_64 systems
- `linux/arm64` - ARM64 systems (e.g., Apple Silicon, Raspberry Pi 4+)
