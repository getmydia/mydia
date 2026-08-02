# Quick Start

Get Mydia up and running in just a few minutes using Docker Compose.

## Prerequisites

- Docker and Docker Compose installed
- A directory for your media files
- A directory for Mydia configuration

## Step 1: Generate Required Secrets

Mydia requires two secret keys for security. Generate them using OpenSSL:

```bash
# Generate SECRET_KEY_BASE
openssl rand -base64 48

# Generate GUARDIAN_SECRET_KEY
openssl rand -base64 48
```

Save these values - you'll need them in the next step.

## Step 2: Create Docker Compose File

Create a `docker-compose.yml` file:

```yaml
services:
  mydia:
    image: ghcr.io/getmydia/mydia:latest
    container_name: mydia
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=America/New_York
      - SECRET_KEY_BASE=your-secret-key-base-here
      - GUARDIAN_SECRET_KEY=your-guardian-secret-key-here
      - PHX_HOST=localhost
      - PORT=4000
      - MOVIES_PATH=/media/library/movies
      - TV_PATH=/media/library/tv
    volumes:
      - /path/to/mydia/config:/config
      - /path/to/your/media:/media
    ports:
      - 4000:4000
    restart: unless-stopped
```

Replace the placeholder values:

- `your-secret-key-base-here` - Your generated SECRET_KEY_BASE
- `your-guardian-secret-key-here` - Your generated GUARDIAN_SECRET_KEY
- `/path/to/mydia/config` - Directory for Mydia configuration and database
- `/path/to/your/media` - Your media directory

## Step 3: Start Mydia

```bash
docker compose up -d
```

## Step 4: Access the Web Interface

Open your browser and navigate to `http://localhost:4000`.

On first visit, you'll be guided through creating the initial admin user.

## Step 5: Configure Your Setup

1. **Add Download Clients** - Configure qBittorrent, Transmission, rqbit, SABnzbd, or NZBGet
2. **Add Indexers** - Set up Prowlarr or Jackett for searching releases
3. **Scan Your Library** - Let Mydia discover your existing media

## Next Steps

- [Installation Options](../how-to/install-docker-compose.md) - Alternative installation methods
- [First Steps](../../getting-started/first-steps.md) - Detailed guide for initial configuration
- [Managing Libraries](../how-to/manage-libraries.md) - Set up your media libraries
