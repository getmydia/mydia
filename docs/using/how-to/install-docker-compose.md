# Installation

Mydia is distributed as a Docker image. This guide covers the container options:
architectures, database variants, volumes, and a full stack you can copy.

Building and running from a source checkout is a development workflow, covered in
[Development Setup](../../contributing/setup.md).

## Prerequisites

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| CPU | 1 core | 2+ cores |
| RAM | 512MB | 1GB+ |
| Disk | 1GB (plus media storage) | SSD storage for the database |

## Supported Architectures

Released images are multi-arch. `ghcr.io/getmydia/mydia:latest` resolves to the
right build for your machine, so you should not need to name an architecture.

| Architecture | Released images |
|:------------:|:---------------:|
| x86-64 (amd64) | Yes |
| arm64 (Apple Silicon, Raspberry Pi 4/5) | Yes |

Per-architecture tags exist as build inputs to the multi-arch manifest, in the form
`<version>[-pg]-<arch>`, for example `1.4.0-arm64` or `1.4.0-pg-amd64`. They are
pinned to one exact version and are not the tags you want for a normal install.
There is no `amd64-latest` or `arm64-latest`.

## Database Variants

| Image Tag | Database | Use Case |
|-----------|----------|----------|
| `latest` | SQLite | Default, simpler setup, single-file database |
| `latest-pg` | PostgreSQL | Scalability, existing PostgreSQL infrastructure |

Every release tag comes in both flavours: the plain tag is SQLite and the `-pg`
suffix is PostgreSQL. So `latest`/`latest-pg`, `1.4`/`1.4-pg`, `1.4.0`/`1.4.0-pg`.
Pre-releases publish `beta` and `beta-pg` instead of moving `latest`.

## Docker Compose (Recommended)

See [Get Mydia Running](../tutorials/get-mydia-running.md) for a minimal Docker Compose setup.

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
| `/media` | Your media tree, mounted as a single volume |

Mount `/media` once and lay your libraries out underneath it, which is what makes
hardlinking work (see below). The paths in the examples on this page are:

| Path inside the container | Contents |
|---|---|
| `/media/library/movies` | Movies library, set with `MOVIES_PATH` |
| `/media/library/tv` | TV library, set with `TV_PATH` |
| `/media/downloads` | Download client output |

These are conventions, not requirements. Point `MOVIES_PATH` and `TV_PATH` wherever
you like, as long as the paths exist inside the container and Mydia can write to
them.

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
