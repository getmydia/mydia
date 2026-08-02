# Installation

Mydia can be installed using Docker (recommended) or from source for development.

## Prerequisites

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| CPU | 1 core | 2+ cores |
| RAM | 512MB | 1GB+ |
| Disk | 1GB (plus media storage) | SSD storage for the database |

## Supported Architectures

Multi-platform images are available for the following architectures:

| Architecture | Available | Tag |
|:------------:|:---------:|-----|
| x86-64 | Yes | amd64-latest |
| arm64 | Yes | arm64-latest |

The multi-arch image `ghcr.io/getmydia/mydia:latest` automatically pulls the correct image for your architecture.

## Database Variants

| Image Tag | Database | Use Case |
|-----------|----------|----------|
| `latest` | SQLite | Default, simpler setup, single-file database |
| `latest-pg` | PostgreSQL | Scalability, existing PostgreSQL infrastructure |

## Docker Compose (Recommended)

See the [Quick Start](../tutorials/get-mydia-running.md) guide for a minimal Docker Compose setup.

## Complete Stack Example

A production-ready setup with Mydia, Transmission (torrent client), and Prowlarr (indexer manager):

```yaml
services:
  # =============================================================================
  # MYDIA - Media Management
  # =============================================================================
  mydia:
    image: ghcr.io/getmydia/mydia:latest
    container_name: mydia
    environment:
      # --- Required Secrets (generate with: openssl rand -base64 48) ---
      - SECRET_KEY_BASE=your-64-character-secret-key-base-here
      - GUARDIAN_SECRET_KEY=your-64-character-guardian-secret-here

      # --- Container Settings ---
      - PUID=1000
      - PGID=1000
      - TZ=America/New_York

      # --- Server Settings ---
      - PHX_HOST=mydia.local
      - PORT=4000
      - URL_SCHEME=http

      # --- Media Library Paths ---
      - MOVIES_PATH=/media/library/movies
      - TV_PATH=/media/library/tv

      # --- Transmission Download Client ---
      - DOWNLOAD_CLIENT_1_NAME=Transmission
      - DOWNLOAD_CLIENT_1_TYPE=transmission
      - DOWNLOAD_CLIENT_1_ENABLED=true
      - DOWNLOAD_CLIENT_1_HOST=transmission
      - DOWNLOAD_CLIENT_1_PORT=9091
      - DOWNLOAD_CLIENT_1_USERNAME=admin
      - DOWNLOAD_CLIENT_1_PASSWORD=transmission
      - DOWNLOAD_CLIENT_1_CATEGORY=mydia
      - DOWNLOAD_CLIENT_1_DOWNLOAD_DIRECTORY=/media/downloads

      # --- Prowlarr Indexer ---
      - INDEXER_1_NAME=Prowlarr
      - INDEXER_1_TYPE=prowlarr
      - INDEXER_1_ENABLED=true
      - INDEXER_1_BASE_URL=http://prowlarr:9696
      - INDEXER_1_API_KEY=your-prowlarr-api-key-here
    volumes:
      - ./config/mydia:/config
      - /path/to/media:/media
    ports:
      - "4000:4000"
    depends_on:
      - transmission
      - prowlarr
    restart: unless-stopped

  # =============================================================================
  # TRANSMISSION - Torrent Client
  # =============================================================================
  transmission:
    image: lscr.io/linuxserver/transmission:latest
    container_name: transmission
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=America/New_York
      - USER=admin
      - PASS=transmission
    volumes:
      - ./config/transmission:/config
      - /path/to/media/downloads:/media/downloads
    ports:
      - "9091:9091"
      - "51413:51413"
      - "51413:51413/udp"
    restart: unless-stopped

  # =============================================================================
  # PROWLARR - Indexer Manager
  # =============================================================================
  prowlarr:
    image: lscr.io/linuxserver/prowlarr:latest
    container_name: prowlarr
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=America/New_York
    volumes:
      - ./config/prowlarr:/config
    ports:
      - "9696:9696"
    restart: unless-stopped
```

!!! tip "Getting Your Prowlarr API Key"
    1. Start the stack: `docker compose up -d`
    2. Access Prowlarr at `http://localhost:9696`
    3. Go to **Settings → General** and copy the **API Key**
    4. Update `INDEXER_1_API_KEY` in your compose file
    5. Restart Mydia: `docker compose restart mydia`

## Docker CLI

```bash
docker run -d \
  --name=mydia \
  -e PUID=1000 \
  -e PGID=1000 \
  -e TZ=America/New_York \
  -e SECRET_KEY_BASE=your-secret-key-base-here \
  -e GUARDIAN_SECRET_KEY=your-guardian-secret-key-here \
  -e PHX_HOST=localhost \
  -e PORT=4000 \
  -e MOVIES_PATH=/media/library/movies \
  -e TV_PATH=/media/library/tv \
  -p 4000:4000 \
  -v /path/to/mydia/config:/config \
  -v /path/to/your/media:/media \
  --restart unless-stopped \
  ghcr.io/getmydia/mydia:latest
```

## Volume Mappings

| Volume | Function |
|:------:|----------|
| `/config` | Application data, database, and configuration files |
| `/media/movies` | Movies library location |
| `/media/tv` | TV shows library location |
| `/media/downloads` | Download client output directory (optional) |

## Hardlink Support

For optimal storage efficiency, Mydia uses hardlinks when importing media. To enable hardlinks, ensure your downloads and library directories are on the same filesystem:

```yaml
volumes:
  - /path/to/mydia/config:/config
  - /path/to/your/media:/media  # Single mount for downloads AND libraries
```

Organize your host directory structure:

```
/path/to/your/media/
  ├── downloads/          # Download client output
  └── library/
      ├── movies/         # Movies library
      └── tv/             # TV library
```

**Benefits:**

- Instant file operations (no data copying)
- Zero duplicate storage space
- Files remain seeding while available in your library

## User/Group Identifiers

To avoid permission issues, specify the user `PUID` and group `PGID`:

```bash
id your_user
# Example output: uid=1000(your_user) gid=1000(your_user)
```

Use these values for `PUID` and `PGID` in your container configuration.

## Troubleshooting

### Container Won't Start

1. Check logs: `docker compose logs mydia`
2. Verify required environment variables are set
3. Check volume permissions

## Next Steps

- [Managing Libraries](manage-libraries.md) - Configure your media libraries
- [Environment Variables](../reference/environment-variables.md) - Complete configuration reference
