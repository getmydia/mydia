# Get Mydia Running

By the end of this tutorial, Mydia will be running with a working admin account and two empty libraries (movies and TV shows), ready for media. It takes about 10 minutes.

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

This uses SQLite, Mydia's default database, so there's no extra database service to set up.

Replace the placeholder values:

- `your-secret-key-base-here` - Your generated SECRET_KEY_BASE
- `your-guardian-secret-key-here` - Your generated GUARDIAN_SECRET_KEY
- `/path/to/mydia/config` - Directory for Mydia configuration and database
- `/path/to/your/media` - Your media directory

## Step 3: Start Mydia

```bash
docker compose up -d
```

## Step 4: Create Your Admin Account

Open your browser and navigate to `http://localhost:4000`.

On first visit, Mydia walks you through creating the initial admin user: set a password of your own, or generate a secure one that's shown once on screen. Submit the form and Mydia creates the account, logs you in automatically, and lands you on the dashboard.

You now have Mydia running with an admin account and two empty libraries. Continue to [Import Your First Movie](first-library-import.md) to bring a file in and watch Mydia match it.
