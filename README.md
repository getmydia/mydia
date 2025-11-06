# 🎬 Mydia

> Your personal media companion, built with Phoenix LiveView

A modern, self-hosted media management platform for tracking, organizing, and monitoring your media library.

## ✨ Features

### Core Library Management
- 📺 **Smart Media Library** – Track TV shows, movies, and episodes with rich metadata from TMDB/TVDB
- 🔍 **Media Discovery** – Search and add content with automatic metadata matching and disambiguation
- 📁 **Library Scanner** – Automatic scanning and import of existing media files
- 🎬 **Detailed Media Pages** – View comprehensive information including cast, crew, seasons, and episodes
- 📊 **Quality Profiles** – Customizable quality preferences for automated downloads

### Download Management
- ⬇️ **Download Client Integration** – Seamless connectivity with qBittorrent and Transmission
- 🔎 **Indexer Support** – Integrated search via Prowlarr and Jackett for finding releases
- 🤖 **Automatic Search & Download** – Background jobs to automatically find and download monitored content
- 🎯 **Smart Release Ranking** – Pluggable scoring system to select the best matching releases
- 📥 **Manual Search** – Browse and select specific releases from the UI
- 📋 **Download Queue** – Real-time monitoring of active downloads with progress tracking

### Monitoring & Tracking
- 🔔 **Release Calendar** – Track upcoming and past releases with timeline view
- 👁️ **Episode Monitoring** – Monitor individual episodes, seasons, or entire series
- 📊 **Missing Episodes** – Identify gaps in your library
- ⏱️ **Background Jobs** – Automated scanning, searching, and importing with Oban

### System & Configuration
- ⚙️ **Admin Dashboard** – System status, configuration management, and health monitoring
- 🔧 **Flexible Configuration** – Environment variables, YAML files, or database settings with clear precedence
- 🎨 **Modern UI** – Built with Phoenix LiveView, Tailwind CSS, and DaisyUI
- 🐳 **Docker Ready** – Pre-built images for amd64 and arm64 platforms
- 🔐 **Local Authentication** – Built-in user management (OIDC support coming soon)

## 📸 Screenshots

<table>
  <tr>
    <td><img src="screenshots/homepage.png" alt="Dashboard" /></td>
    <td><img src="screenshots/movies.png" alt="Movies" /></td>
  </tr>
  <tr>
    <td align="center"><b>Dashboard</b></td>
    <td align="center"><b>Movies</b></td>
  </tr>
  <tr>
    <td><img src="screenshots/tv-shows.png" alt="TV Shows" /></td>
    <td><img src="screenshots/calendar.png" alt="Calendar View" /></td>
  </tr>
  <tr>
    <td align="center"><b>TV Shows</b></td>
    <td align="center"><b>Calendar View</b></td>
  </tr>
  <tr>
    <td><img src="screenshots/search.png" alt="Search" /></td>
    <td></td>
  </tr>
  <tr>
    <td align="center"><b>Search</b></td>
    <td></td>
  </tr>
</table>

## 🏗️ Supported Architectures

Multi-platform images are available for the following architectures:

| Architecture | Available | Tag |
| :----: | :----: | ---- |
| x86-64 | ✅ | amd64-latest |
| arm64 | ✅ | arm64-latest |

The multi-arch image `ghcr.io/getmydia/mydia:latest` will automatically pull the correct image for your architecture.

## 🚀 Application Setup

1. **Generate required secrets:**

```bash
# Generate SECRET_KEY_BASE
openssl rand -base64 48

# Generate GUARDIAN_SECRET_KEY
openssl rand -base64 48
```

2. Set up your container using Docker Compose (recommended) or Docker CLI
3. Access the web interface at `http://your-server:4000`
4. On first startup, a default admin user is automatically created:
   - Check the container logs for the generated password
   - Default username: `admin` (configurable via `ADMIN_USERNAME`)
   - Or set `ADMIN_PASSWORD_HASH` to use a pre-hashed password
5. Configure download clients and indexers in the Admin section

## 📦 Usage

Here are some example snippets to help you get started creating a container.

### Docker Compose (Recommended)

```yaml
---
services:
  mydia:
    image: ghcr.io/getmydia/mydia:latest
    container_name: mydia
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=America/New_York
      - SECRET_KEY_BASE=your-secret-key-base-here  # Required: generate with openssl rand -base64 48
      - GUARDIAN_SECRET_KEY=your-guardian-secret-key-here  # Required: generate with openssl rand -base64 48
      - PHX_HOST=localhost  # Change to your domain
      - PORT=4000
      - MOVIES_PATH=/media/movies
      - TV_PATH=/media/tv
    volumes:
      - /path/to/mydia/config:/config
      - /path/to/your/movies:/media/movies
      - /path/to/your/tv:/media/tv
      - /path/to/your/downloads:/media/downloads
    ports:
      - 4000:4000
    restart: unless-stopped
```

### Docker CLI

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
  -e MOVIES_PATH=/media/movies \
  -e TV_PATH=/media/tv \
  -p 4000:4000 \
  -v /path/to/mydia/config:/config \
  -v /path/to/your/movies:/media/movies \
  -v /path/to/your/tv:/media/tv \
  -v /path/to/your/downloads:/media/downloads \
  --restart unless-stopped \
  ghcr.io/getmydia/mydia:latest
```

## 📋 Parameters

Container images are configured using parameters passed at runtime. These parameters are separated by a colon and indicate `external:internal` respectively.

### Ports (`-p`)

| Parameter | Function |
| :----: | --- |
| `4000:4000` | Web interface |

### Environment Variables (`-e`)

| Env | Function |
| :----: | --- |
| `PUID=1000` | User ID for file permissions - see [User / Group Identifiers](#user--group-identifiers) below |
| `PGID=1000` | Group ID for file permissions - see [User / Group Identifiers](#user--group-identifiers) below |
| `TZ=UTC` | Timezone (e.g., `America/New_York`) |
| `SECRET_KEY_BASE` | **Required** - Phoenix secret key (generate with: `openssl rand -base64 48`) |
| `GUARDIAN_SECRET_KEY` | **Required** - JWT signing key (generate with: `openssl rand -base64 48`) |
| `PHX_HOST=localhost` | Public hostname for the application |
| `PORT=4000` | Web server port |
| `MOVIES_PATH=/media/movies` | Movies directory path |
| `TV_PATH=/media/tv` | TV shows directory path |

See the **[Environment Variables Reference](#-environment-variables-reference)** section below for complete configuration options including download clients, indexers, and authentication.

### Volume Mappings (`-v`)

| Volume | Function |
| :----: | --- |
| `/config` | Application data, database, and configuration files |
| `/media/movies` | Movies library location |
| `/media/tv` | TV shows library location |
| `/media/downloads` | Download client output directory (optional) |

## 👤 User / Group Identifiers

When using volumes (`-v` flags), permissions issues can arise between the host and container. To avoid this, specify the user `PUID` and group `PGID` to ensure files created by the container are owned by your user.

**Finding your IDs:**

```bash
id your_user
```

Example output: `uid=1000(your_user) gid=1000(your_user)`

Use these values for `PUID` and `PGID` in your container configuration.

## 🔄 Updating the Container

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

**Note:** Migrations run automatically on startup. Your data in `/config` is preserved across updates.

See [DEPLOYMENT.md](docs/deployment/DEPLOYMENT.md) for advanced deployment topics.

## 📋 Environment Variables Reference

### Required Variables

| Variable | Description | Example |
|----------|-------------|---------|
| `SECRET_KEY_BASE` | Phoenix secret key for cookies/sessions | Generate with: `openssl rand -base64 48` |
| `GUARDIAN_SECRET_KEY` | JWT signing key for authentication | Generate with: `openssl rand -base64 48` |

### Container Configuration

| Variable | Description | Default |
|----------|-------------|---------|
| `PUID` | User ID for file permissions | `1000` |
| `PGID` | Group ID for file permissions | `1000` |
| `TZ` | Timezone (e.g., `America/New_York`, `Europe/London`) | `UTC` |
| `DATABASE_PATH` | Path to SQLite database file | `/config/mydia.db` |

### Server Configuration

| Variable | Description | Default |
|----------|-------------|---------|
| `PHX_HOST` | Public hostname for the application | `localhost` |
| `PORT` | Web server port | `4000` |
| `HOST` | Server binding address | `0.0.0.0` |
| `URL_SCHEME` | URL scheme for external links (http/https) | `http` |

### Media Library

| Variable | Description | Default |
|----------|-------------|---------|
| `MOVIES_PATH` | Movies directory path | `/media/movies` |
| `TV_PATH` | TV shows directory path | `/media/tv` |
| `MEDIA_SCAN_INTERVAL_HOURS` | Hours between library scans | `1` |

### Authentication

| Variable | Description | Default |
|----------|-------------|---------|
| `LOCAL_AUTH_ENABLED` | Enable local username/password auth | `true` |
| `ADMIN_USERNAME` | Default admin username (created on first startup) | `admin` |
| `ADMIN_EMAIL` | Default admin email (created on first startup) | `admin@mydia.local` |
| `ADMIN_PASSWORD_HASH` | Pre-hashed admin password (bcrypt). If not set, a random password is generated and logged | - |
| `OIDC_ENABLED` | Enable OIDC/OpenID Connect auth | `false` |
| `OIDC_DISCOVERY_DOCUMENT_URI` | OIDC discovery endpoint URL | - |
| `OIDC_CLIENT_ID` | OIDC client ID | - |
| `OIDC_CLIENT_SECRET` | OIDC client secret | - |
| `OIDC_REDIRECT_URI` | OIDC callback URL | Auto-computed |
| `OIDC_SCOPES` | Space-separated scope list | `openid profile email` |

**Admin User Creation:**

On first startup, if no admin user exists, Mydia automatically creates one:
- **Random Password** (default): A secure random password is generated and displayed in the container logs
- **Pre-set Password**: Use `ADMIN_PASSWORD_HASH` with a bcrypt hash for production deployments

Generate a bcrypt hash:
```bash
# Using Elixir/Mix (if available)
mix run -e "IO.puts Bcrypt.hash_pwd_salt(\"your_secure_password\")"

# Using Python
python3 -c "import bcrypt; print(bcrypt.hashpw(b'your_secure_password', bcrypt.gensalt()).decode())"
```

### Download Clients

Configure multiple download clients using numbered environment variables (`<N>` = 1, 2, 3, etc.):

| Variable Pattern | Description | Example |
|-----------------|-------------|---------|
| `DOWNLOAD_CLIENT_<N>_NAME` | Client display name | `qBittorrent` |
| `DOWNLOAD_CLIENT_<N>_TYPE` | Client type (qbittorrent, transmission, http) | `qbittorrent` |
| `DOWNLOAD_CLIENT_<N>_ENABLED` | Enable this client | `true` |
| `DOWNLOAD_CLIENT_<N>_PRIORITY` | Client priority (higher = preferred) | `1` |
| `DOWNLOAD_CLIENT_<N>_HOST` | Client hostname or IP | `qbittorrent` |
| `DOWNLOAD_CLIENT_<N>_PORT` | Client port | `8080` |
| `DOWNLOAD_CLIENT_<N>_USE_SSL` | Use SSL/TLS connection | `false` |
| `DOWNLOAD_CLIENT_<N>_USERNAME` | Authentication username | - |
| `DOWNLOAD_CLIENT_<N>_PASSWORD` | Authentication password | - |
| `DOWNLOAD_CLIENT_<N>_CATEGORY` | Default download category | - |
| `DOWNLOAD_CLIENT_<N>_DOWNLOAD_DIRECTORY` | Download output directory | - |

Example for two download clients:

```bash
# qBittorrent
DOWNLOAD_CLIENT_1_NAME=qBittorrent
DOWNLOAD_CLIENT_1_TYPE=qbittorrent
DOWNLOAD_CLIENT_1_HOST=qbittorrent
DOWNLOAD_CLIENT_1_PORT=8080
DOWNLOAD_CLIENT_1_USERNAME=admin
DOWNLOAD_CLIENT_1_PASSWORD=adminpass

# Transmission
DOWNLOAD_CLIENT_2_NAME=Transmission
DOWNLOAD_CLIENT_2_TYPE=transmission
DOWNLOAD_CLIENT_2_HOST=transmission
DOWNLOAD_CLIENT_2_PORT=9091
DOWNLOAD_CLIENT_2_USERNAME=admin
DOWNLOAD_CLIENT_2_PASSWORD=adminpass
```

### Indexers

Configure multiple indexers using numbered environment variables (`<N>` = 1, 2, 3, etc.):

| Variable Pattern | Description | Example |
|-----------------|-------------|---------|
| `INDEXER_<N>_NAME` | Indexer display name | `Prowlarr` |
| `INDEXER_<N>_TYPE` | Indexer type (prowlarr, jackett, public) | `prowlarr` |
| `INDEXER_<N>_ENABLED` | Enable this indexer | `true` |
| `INDEXER_<N>_PRIORITY` | Indexer priority (higher = preferred) | `1` |
| `INDEXER_<N>_BASE_URL` | Indexer base URL | `http://prowlarr:9696` |
| `INDEXER_<N>_API_KEY` | Indexer API key | - |
| `INDEXER_<N>_INDEXER_IDS` | Comma-separated indexer IDs | `1,2,3` |
| `INDEXER_<N>_CATEGORIES` | Comma-separated categories | `movies,tv` |
| `INDEXER_<N>_RATE_LIMIT` | API rate limit (requests/sec) | - |

Example for Prowlarr:

```bash
INDEXER_1_NAME=Prowlarr
INDEXER_1_TYPE=prowlarr
INDEXER_1_BASE_URL=http://prowlarr:9696
INDEXER_1_API_KEY=your-prowlarr-api-key-here
```

Example for Jackett:

```bash
INDEXER_2_NAME=Jackett
INDEXER_2_TYPE=jackett
INDEXER_2_BASE_URL=http://jackett:9117
INDEXER_2_API_KEY=your-jackett-api-key-here
```

### Advanced Configuration

| Variable | Description | Default |
|----------|-------------|---------|
| `LOG_LEVEL` | Application log level (debug, info, warning, error) | `info` |

### Configuration Precedence

Configuration is loaded in this order (highest to lowest priority):

1. **Environment Variables** - Override everything
2. **Database Settings** - Configured via Admin UI
3. **YAML File** - From `config/config.yml`
4. **Schema Defaults** - Built-in defaults

## 🔧 Development

### Local Setup

**With Docker (Recommended):**

```bash
# Start everything
./dev up -d

# Run migrations
./dev mix ecto.migrate

# View at http://localhost:4000
# Check logs for the auto-generated admin password:
./dev logs | grep "DEFAULT ADMIN USER CREATED" -A 10
```

See all commands with `./dev`

**Without Docker:**

```bash
mix setup
mix phx.server
```

Visit [localhost:4000](http://localhost:4000)

### Continuous Integration

All pull requests and commits to the main branch automatically run:
- ✓ Code compilation with warnings as errors
- ✓ Code formatting checks
- ✓ Static analysis with Credo
- ✓ Full test suite
- ✓ Docker build verification

Run these checks locally before committing:

```bash
mix precommit
```

### Customization

Create `compose.override.yml` to add services like Transmission, Prowlarr, Jackett, or custom configurations:

```bash
cp compose.override.yml.example compose.override.yml
# Edit and uncomment services you need
./dev up -d
```

### Screenshots

Capture automated screenshots for documentation:

```bash
./take-screenshots
```

See `assets/SCREENSHOTS.md` for configuration options.

## 🛠️ Tech Stack

- Phoenix 1.8 + LiveView
- Ecto + SQLite
- Oban (background jobs)
- Tailwind CSS + DaisyUI
- Req (HTTP client)

---

Built with Elixir & Phoenix
