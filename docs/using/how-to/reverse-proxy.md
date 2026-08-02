# Deployment Guide

Advanced deployment topics for production environments.

## Updating Mydia

### Via Docker Compose

```bash
docker compose pull
docker compose up -d
```

### Via Docker CLI

```bash
docker stop mydia
docker rm mydia
docker pull ghcr.io/getmydia/mydia:latest
# Run your docker run command again
```

Migrations run automatically on startup. Your data in `/config` is preserved.

## Reverse Proxy Configuration

### Nginx

```nginx
server {
    listen 80;
    server_name mydia.example.com;

    location / {
        proxy_pass http://localhost:4000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

### Traefik

```yaml
labels:
  - "traefik.enable=true"
  - "traefik.http.routers.mydia.rule=Host(`mydia.example.com`)"
  - "traefik.http.routers.mydia.entrypoints=websecure"
  - "traefik.http.routers.mydia.tls.certresolver=letsencrypt"
  - "traefik.http.services.mydia.loadbalancer.server.port=4000"
```

### Caddy

```caddy
mydia.example.com {
    reverse_proxy localhost:4000
}
```

## HTTPS Configuration

Configure Mydia for HTTPS access:

```bash
PHX_HOST=mydia.example.com
URL_SCHEME=https
```

SSL termination should be handled by your reverse proxy.

## WebSocket Configuration

For LiveView real-time features to work through a reverse proxy, ensure WebSocket connections are properly proxied:

- Nginx: Include `proxy_set_header Upgrade` and `Connection "upgrade"`
- Traefik: Automatic WebSocket support
- Caddy: Automatic WebSocket support

## Origin Checking

By default, Mydia checks WebSocket origins for security. Configure as needed:

```bash
# Allow all origins (for IP-based access)
PHX_CHECK_ORIGIN=false

# Allow specific origins
PHX_CHECK_ORIGIN=https://mydia.example.com,http://192.168.1.100:4000
```

## Backup Strategy

### Automatic Backups

Mydia creates automatic database backups before migrations:

- Stored alongside the database
- 10 most recent backups retained
- Disable with `SKIP_BACKUPS=true` (not recommended)

### Manual Backup

For SQLite:

```bash
# Stop container
docker compose stop mydia

# Backup
cp /path/to/config/mydia.db /path/to/backup/mydia_$(date +%Y%m%d).db

# Start container
docker compose start mydia
```

### Restore

```bash
# Stop container
docker compose stop mydia

# Restore
cp /path/to/backup/mydia_20240101.db /path/to/config/mydia.db

# Start container
docker compose start mydia
```

## Monitoring

### Health Checks

Mydia exposes a health endpoint:

```bash
curl http://localhost:4000/health
```

### Docker Health Check

```yaml
services:
  mydia:
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:4000/health"]
      interval: 30s
      timeout: 10s
      retries: 3
```

### Logs

View container logs:

```bash
docker compose logs -f mydia
```

Configure log level:

```bash
LOG_LEVEL=debug  # or info, warning, error
```

## High Availability

!!! note
    High availability configurations are not officially supported but may work with PostgreSQL.

For HA deployments:

1. Use PostgreSQL (external database)
2. Deploy multiple Mydia instances behind a load balancer
3. Ensure shared storage for `/config` (excluding database)
4. Configure sticky sessions for LiveView

## Beta Releases

Test new features before stable release:

```yaml
services:
  mydia:
    image: ghcr.io/getmydia/mydia:beta
```

Beta releases:

- May contain experimental features
- May have breaking changes
- Not recommended for production

## Version Pinning

Pin to a specific version for stability:

```yaml
services:
  mydia:
    image: ghcr.io/getmydia/mydia:1.0.0
```

## Resource Requirements

### Minimum

- 1 CPU core
- 512MB RAM
- 1GB disk (plus media storage)

### Recommended

- 2+ CPU cores
- 1GB+ RAM
- SSD storage for database

## NixOS Deployment

Mydia provides a NixOS module for declarative deployment:

### Flake Configuration

```nix
# flake.nix
{
  inputs.mydia.url = "github:getmydia/mydia";

  outputs = { self, nixpkgs, mydia }: {
    nixosConfigurations.myserver = nixpkgs.lib.nixosSystem {
      modules = [ mydia.nixosModules.default ./configuration.nix ];
    };
  };
}
```

### Module Configuration

```nix
# configuration.nix
{
  services.mydia = {
    enable = true;
    host = "mydia.example.com";
    secretKeyBaseFile = "/run/secrets/mydia/secret_key_base";
    guardianSecretKeyFile = "/run/secrets/mydia/guardian_secret_key";
    mediaLibraries = [ "/mnt/media/movies" "/mnt/media/tv" ];
  };
}
```

### Features

The NixOS module supports:

- OIDC authentication configuration
- Download client setup
- FlareSolverr integration
- Systemd security hardening
- Secrets management via files

See [docs/nix.md](https://github.com/getmydia/mydia/blob/master/docs/nix.md) in the repository for complete configuration options.

## Troubleshooting

### Container Won't Start

1. Check logs: `docker compose logs mydia`
2. Verify required environment variables are set
3. Check volume permissions

### Database Errors

1. Check disk space
2. Verify database file permissions
3. Try restoring from backup

### Connection Issues

1. Verify port mapping
2. Check firewall rules
3. Test with `curl http://localhost:4000`
