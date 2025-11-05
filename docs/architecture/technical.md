# Mydia - Technical Architecture

## Overview

Mydia is built with simplicity and self-hosting in mind. The application uses **SQLite as the default database**, eliminating the need for separate database containers or complex configuration. This makes deployment as simple as running a single Docker container or binary.

**Key Design Principles:**
- 🗃️ **SQLite-First**: Zero-configuration database that's perfect for self-hosting
- 🐳 **Docker-Optimized**: Single container deployment with persistent volumes
- 🔐 **OIDC Native**: First-class support for modern authentication
- ⚡ **Elixir/OTP**: Concurrent, fault-tolerant, and resource-efficient
- 📦 **Batteries Included**: Everything needed in one package

## Technology Stack

### Core Framework
- **Phoenix Framework 1.7+**: Web framework and real-time capabilities
- **Elixir/OTP**: Concurrent, fault-tolerant application platform
- **SQLite3**: Embedded database for simple, zero-configuration deployment
- **LiveView**: Real-time UI updates without JavaScript complexity

### Authentication & Security
- **OpenID Connect (OIDC)**: Primary authentication mechanism
- **Guardian**: JWT token management for API authentication
- **Ueberauth**: Extensible authentication strategy system
- **HTTPS-only**: Enforced secure connections

### Infrastructure
- **Docker**: Multi-stage builds for minimal image size
- **Docker Compose**: Local development and simple deployments
- **Health Checks**: Container orchestration readiness probes
- **Prometheus Metrics**: Operational observability

### Data & Storage
- **Ecto + Ecto_SQLite3**: Database abstraction and SQLite adapter
- **Oban**: Background job processing with reliability (SQLite-compatible)
- **File System**: Media file management with configurable paths
- **S3-Compatible**: Optional object storage support

### Why SQLite?
- **Zero Configuration**: No separate database server required
- **Single File**: Database stored as a single file for easy backups
- **Docker-Friendly**: Simpler container deployment (no multi-container setup needed)
- **Resource Efficient**: Lower memory footprint perfect for self-hosting
- **Performance**: Excellent for read-heavy workloads and small-to-medium libraries
- **Portability**: Move your entire database by copying one file

**Note**: For very large libraries (>50,000 media items) or high-concurrency scenarios, PostgreSQL remains an option via configuration.

## System Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Reverse Proxy                        │
│              (Traefik, Caddy, nginx)                    │
└────────────────────┬────────────────────────────────────┘
                     │
┌────────────────────▼────────────────────────────────────┐
│                  Phoenix Application                     │
├─────────────────────────────────────────────────────────┤
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  │
│  │   LiveView   │  │   REST API   │  │  GraphQL API │  │
│  │  (Web UI)    │  │   (v1/...)   │  │  (/graphql)  │  │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘  │
│         │                 │                  │          │
│  ┌──────┴─────────────────┴──────────────────┴───────┐  │
│  │              Context Layer                         │  │
│  │  - Media Context (movies, shows, episodes)        │  │
│  │  - Library Context (scanning, organizing)         │  │
│  │  - Download Context (search, acquire)             │  │
│  │  - User Context (auth, permissions)               │  │
│  │  - Settings Context (config, profiles)            │  │
│  └────────────────────┬───────────────────────────────┘  │
│                       │                                  │
│  ┌────────────────────▼───────────────────────────────┐  │
│  │              Background Jobs (Oban)                │  │
│  │  - Media scanning                                  │  │
│  │  - Automated search                                │  │
│  │  - Download monitoring                             │  │
│  │  - Quality upgrading                               │  │
│  │  - Webhook dispatch                                │  │
│  └────────────────────┬───────────────────────────────┘  │
│                       │                                  │
│  ┌────────────────────▼───────────────────────────────┐  │
│  │           External Service Adapters                │  │
│  │  - Indexers (Jackett, Prowlarr, native)           │  │
│  │  - Download Clients (qBittorrent, Transmission)   │  │
│  │  - Subtitle Providers (OpenSubtitles, etc.)       │  │
│  │  - Notification Services (webhooks, Discord, etc.)│  │
│  └────────────────────┬───────────────────────────────┘  │
│                       │                                  │
│  ┌────────────────────▼───────────────────────────────┐  │
│  │            Embedded SQLite Database                │  │
│  │           (stored in /data volume)                 │  │
│  └────────────────────────────────────────────────────┘  │
└─────────────────────┬───────────────────────────────────┘
                      │
        ┌─────────────┴─────────────┐
        │                           │
┌───────▼──────┐              ┌─────▼────────┐
│     File     │              │  Download    │
│    System    │              │   Clients    │
│ (Media Files)│              │              │
└──────────────┘              └──────────────┘
```

## Core Components

### 1. Media Management

#### Database Schema (Core Tables)

SQLite-compatible schema using TEXT for UUIDs and JSON, with CHECK constraints for enums:

```sql
-- Media items (movies and TV shows)
CREATE TABLE media_items (
  id TEXT PRIMARY KEY,  -- UUID stored as text
  type TEXT NOT NULL CHECK(type IN ('movie', 'tv_show')),
  title TEXT NOT NULL,
  original_title TEXT,
  year INTEGER,
  tmdb_id INTEGER UNIQUE,
  imdb_id TEXT,
  metadata TEXT,  -- JSON stored as text (SQLite JSON1 extension)
  monitored INTEGER DEFAULT 1,  -- SQLite uses 0/1 for boolean
  created_at TEXT NOT NULL,  -- ISO8601 timestamp
  updated_at TEXT NOT NULL
);

CREATE INDEX idx_media_items_tmdb ON media_items(tmdb_id);
CREATE INDEX idx_media_items_imdb ON media_items(imdb_id);
CREATE INDEX idx_media_items_title ON media_items(title);
CREATE INDEX idx_media_items_type ON media_items(type);

-- Episodes (for TV shows)
CREATE TABLE episodes (
  id TEXT PRIMARY KEY,
  media_item_id TEXT NOT NULL REFERENCES media_items(id) ON DELETE CASCADE,
  season_number INTEGER NOT NULL,
  episode_number INTEGER NOT NULL,
  title TEXT,
  air_date TEXT,  -- ISO8601 date
  metadata TEXT,  -- JSON
  monitored INTEGER DEFAULT 1,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE(media_item_id, season_number, episode_number)
);

CREATE INDEX idx_episodes_media_item ON episodes(media_item_id);
CREATE INDEX idx_episodes_air_date ON episodes(air_date);

-- Media files (multiple versions support)
CREATE TABLE media_files (
  id TEXT PRIMARY KEY,
  media_item_id TEXT REFERENCES media_items(id) ON DELETE CASCADE,
  episode_id TEXT REFERENCES episodes(id) ON DELETE CASCADE,
  path TEXT NOT NULL UNIQUE,
  size INTEGER,  -- Bytes
  quality_profile_id TEXT REFERENCES quality_profiles(id),

  -- Version metadata
  resolution TEXT,  -- '1080p', '4K', etc.
  codec TEXT,       -- 'h264', 'h265', 'av1'
  hdr_format TEXT,  -- 'HDR10', 'HDR10+', 'DolbyVision'
  audio_codec TEXT, -- 'AAC', 'DTS-HD', 'Atmos'
  bitrate INTEGER,  -- kbps

  -- File metadata
  created_at TEXT NOT NULL,
  verified_at TEXT,
  metadata TEXT,  -- JSON for additional flexible metadata

  -- Ensure one of media_item_id or episode_id is set
  CHECK(
    (media_item_id IS NOT NULL AND episode_id IS NULL) OR
    (media_item_id IS NULL AND episode_id IS NOT NULL)
  )
);

CREATE INDEX idx_media_files_media_item ON media_files(media_item_id);
CREATE INDEX idx_media_files_episode ON media_files(episode_id);
CREATE INDEX idx_media_files_path ON media_files(path);

-- Quality profiles
CREATE TABLE quality_profiles (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL UNIQUE,
  upgrades_allowed INTEGER DEFAULT 1,
  upgrade_until_quality TEXT,

  -- Ordered list of acceptable qualities (JSON array)
  qualities TEXT NOT NULL,

  -- Custom rules (JSON)
  rules TEXT,

  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

-- Download queue
CREATE TABLE downloads (
  id TEXT PRIMARY KEY,
  media_item_id TEXT REFERENCES media_items(id) ON DELETE CASCADE,
  episode_id TEXT REFERENCES episodes(id) ON DELETE CASCADE,

  status TEXT NOT NULL CHECK(status IN ('pending', 'downloading', 'completed', 'failed', 'cancelled')),

  -- Download details
  indexer TEXT,
  title TEXT NOT NULL,
  download_url TEXT,
  download_client TEXT,
  download_client_id TEXT,

  -- Progress
  progress REAL CHECK(progress >= 0 AND progress <= 100),
  estimated_completion TEXT,  -- ISO8601 timestamp

  created_at TEXT NOT NULL,
  completed_at TEXT,
  error_message TEXT,
  metadata TEXT  -- JSON
);

CREATE INDEX idx_downloads_status ON downloads(status);
CREATE INDEX idx_downloads_media_item ON downloads(media_item_id);
CREATE INDEX idx_downloads_episode ON downloads(episode_id);
CREATE INDEX idx_downloads_created_at ON downloads(created_at);

-- Users table (for local auth and OIDC user mapping)
CREATE TABLE users (
  id TEXT PRIMARY KEY,
  username TEXT UNIQUE,
  email TEXT UNIQUE,
  password_hash TEXT,  -- NULL for OIDC-only users

  -- OIDC mapping
  oidc_sub TEXT UNIQUE,  -- Subject claim from OIDC provider
  oidc_issuer TEXT,

  -- Authorization
  role TEXT NOT NULL CHECK(role IN ('admin', 'user', 'readonly')) DEFAULT 'user',

  -- Metadata
  display_name TEXT,
  avatar_url TEXT,
  last_login_at TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE INDEX idx_users_oidc ON users(oidc_sub, oidc_issuer);
CREATE INDEX idx_users_username ON users(username);
CREATE INDEX idx_users_email ON users(email);

-- API keys for programmatic access
CREATE TABLE api_keys (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  key_hash TEXT NOT NULL UNIQUE,
  last_used_at TEXT,
  expires_at TEXT,
  created_at TEXT NOT NULL
);

CREATE INDEX idx_api_keys_user ON api_keys(user_id);
CREATE INDEX idx_api_keys_key_hash ON api_keys(key_hash);
```

**SQLite-specific Optimizations:**
- **WAL Mode**: Write-Ahead Logging for better concurrency
- **Foreign Keys**: Enabled by default in config
- **JSON1 Extension**: For efficient JSON queries
- **PRAGMA Tuning**: Optimized cache size and synchronous mode

### 2. Configuration System

#### Ecto Configuration (SQLite)

```elixir
# config/runtime.exs
config :mydia, Mydia.Repo,
  database: System.get_env("DATABASE_PATH", "/config/mydia.db"),
  pool_size: String.to_integer(System.get_env("POOL_SIZE", "5")),

  # SQLite-specific settings
  timeout: 5000,
  journal_mode: :wal,
  cache_size: -64000,  # 64MB
  temp_store: :memory,
  synchronous: :normal,
  foreign_keys: :on,

  # Handle busy database
  busy_timeout: 5000

# Migration configuration
config :mydia, Mydia.Repo,
  migration_lock: :pg_advisory_lock,  # Not needed for SQLite
  migration_timestamps: [type: :utc_datetime]
```

#### Configuration Sources (Priority Order)
1. Environment variables (highest priority)
2. Runtime config file (`config.yml`)
3. Default values (lowest priority)

#### Configuration Schema

```yaml
# config.yml
server:
  host: "0.0.0.0"
  port: 4000
  secret_key_base: "${SECRET_KEY_BASE}"
  url_scheme: "https"
  url_host: "mydia.example.com"

database:
  # SQLite database file path (relative to /data volume)
  path: "${DATABASE_PATH:-/config/mydia.db}"

  # WAL mode for better concurrency
  wal_mode: true

  # Optional: PostgreSQL for large deployments
  # url: "${DATABASE_URL}"
  # pool_size: 10

auth:
  oidc:
    enabled: true
    issuer: "https://auth.example.com/realms/myrealm"
    client_id: "${OIDC_CLIENT_ID}"
    client_secret: "${OIDC_CLIENT_SECRET}"
    scopes: ["openid", "profile", "email"]

  # Fallback for development
  local_auth_enabled: false

media:
  library_paths:
    - path: "/data/movies"
      type: "movie"
    - path: "/data/tv"
      type: "tv_show"

  # File organization
  naming:
    movie: "{title} ({year})/{title} ({year}) - {quality}"
    episode: "{show}/Season {season}/{show} - S{season:2}E{episode:2} - {title}"

downloads:
  clients:
    - type: "qbittorrent"
      name: "primary"
      url: "http://qbittorrent:8080"
      username: "${QB_USER}"
      password: "${QB_PASS}"

  indexers:
    - type: "prowlarr"
      url: "http://prowlarr:9696"
      api_key: "${PROWLARR_API_KEY}"

notifications:
  webhooks:
    - url: "https://example.com/webhook"
      events: ["download_completed", "media_added"]
```

### 3. Authentication Flow

```
┌──────┐                                    ┌──────────┐
│ User │                                    │  Mydia   │
└───┬──┘                                    └────┬─────┘
    │                                            │
    │  1. Access /                               │
    ├──────────────────────────────────────────>│
    │                                            │
    │  2. Redirect to /auth/oidc                 │
    │<───────────────────────────────────────────┤
    │                                            │
    │  3. Redirect to OIDC Provider              │
    ├────────────────────┐                       │
    │                    │                       │
┌───▼────────────┐       │                       │
│ OIDC Provider  │       │                       │
│ (Authentik)    │       │                       │
└───┬────────────┘       │                       │
    │                    │                       │
    │  4. Login & Consent│                       │
    │<───────────────────┘                       │
    │                                            │
    │  5. Redirect to /auth/oidc/callback        │
    │         with authorization code            │
    ├──────────────────────────────────────────>│
    │                                            │
    │                                  6. Exchange code
    │                                     for tokens
    │                                            │
    │  7. Set session cookie                     │
    │<───────────────────────────────────────────┤
    │                                            │
    │  8. Redirect to /                          │
    │<───────────────────────────────────────────┤
    │                                            │
```

### 4. Background Job Processing

Jobs are processed by Oban with different queues for different priorities. Oban works excellently with SQLite in WAL mode:

```elixir
# Queue Configuration
config :mydia, Oban,
  repo: Mydia.Repo,
  engine: Oban.Engines.Basic,  # SQLite-compatible engine
  queues: [
    critical: 10,    # Health checks, urgent operations
    default: 5,      # Standard background tasks
    media: 3,        # Media scanning, organizing
    search: 2,       # Automated searching
    notifications: 1 # Webhooks, notifications
  ],
  # SQLite-friendly polling
  poll_interval: 1000,

  # Plugins
  plugins: [
    {Oban.Plugins.Pruner, max_age: 86400 * 7},  # Keep jobs for 7 days
    {Oban.Plugins.Cron, crontab: [
      {"0 2 * * *", Mydia.Jobs.LibraryScanner},      # Daily at 2 AM
      {"0 */6 * * *", Mydia.Jobs.AutomatedSearcher}, # Every 6 hours
      {"*/5 * * * *", Mydia.Jobs.DownloadMonitor},   # Every 5 minutes
    ]}
  ]
```

**Note**: Oban uses SQLite's row-level locking in WAL mode for job queue management, providing reliable concurrent job processing without requiring advisory locks.

#### Key Background Jobs

1. **Library Scanner**: Periodically scans media directories for changes
2. **Automated Searcher**: Searches for monitored media on schedule
3. **Download Monitor**: Checks download client status and imports completed files
4. **Quality Upgrader**: Searches for better versions of existing media
5. **Metadata Refresher**: Updates metadata from TMDB/IMDB
6. **Cleanup Worker**: Removes old logs, orphaned files

### 5. API Design

#### REST API

```
# Media Items
GET    /api/v1/media
GET    /api/v1/media/:id
POST   /api/v1/media
PUT    /api/v1/media/:id
DELETE /api/v1/media/:id

# Search & Downloads
GET    /api/v1/search?q=query
POST   /api/v1/downloads
GET    /api/v1/downloads
GET    /api/v1/downloads/:id

# Library Management
POST   /api/v1/library/scan
GET    /api/v1/library/scan-status
GET    /api/v1/files

# Configuration
GET    /api/v1/config
PUT    /api/v1/config
GET    /api/v1/quality-profiles
```

#### GraphQL Schema (Core Types)

```graphql
type MediaItem {
  id: ID!
  type: MediaType!
  title: String!
  year: Int
  files: [MediaFile!]!
  monitored: Boolean!
  metadata: JSON
}

type MediaFile {
  id: ID!
  path: String!
  size: Int!
  resolution: String
  codec: String
  hdrFormat: String
  verified: Boolean!
}

type Query {
  media(id: ID!): MediaItem
  searchMedia(query: String!): [MediaItem!]!
  downloads: [Download!]!
}

type Mutation {
  addMedia(input: AddMediaInput!): MediaItem!
  triggerSearch(mediaId: ID!): SearchResult!
  updateConfig(input: ConfigInput!): Config!
}

type Subscription {
  downloadProgress(id: ID!): Download!
  libraryUpdates: LibraryEvent!
}
```

## Docker Deployment

### Dockerfile (Multi-stage)

```dockerfile
# Build stage
FROM hexpm/elixir:1.16-erlang-26-alpine AS build

RUN apk add --no-cache build-base git nodejs npm

WORKDIR /app

# Dependencies
COPY mix.exs mix.lock ./
RUN mix local.hex --force && \
    mix local.rebar --force && \
    mix deps.get --only prod

# Assets
COPY assets/package*.json assets/
RUN npm --prefix assets ci --progress=false --no-audit

# Compile
COPY . .
RUN mix assets.deploy && \
    mix compile

# Release
RUN mix release

# Runtime stage
FROM alpine:3.19 AS app

RUN apk add --no-cache libstdc++ openssl ncurses-libs

WORKDIR /app

RUN adduser -D -h /app mydia
USER mydia

COPY --from=build --chown=mydia:mydia /app/_build/prod/rel/mydia ./

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=40s \
  CMD /app/bin/mydia rpc "Mydia.Health.check()" || exit 1

EXPOSE 4000

CMD ["/app/bin/mydia", "start"]
```

### Docker Compose Example

```yaml
version: '3.8'

services:
  mydia:
    image: mydia:latest
    container_name: mydia
    restart: unless-stopped
    ports:
      - "4000:4000"
    environment:
      # Application
      SECRET_KEY_BASE: "${SECRET_KEY_BASE}"

      # Database (SQLite - stored in /data volume)
      DATABASE_PATH: "/config/mydia.db"

      # OIDC Authentication
      OIDC_CLIENT_ID: "${OIDC_CLIENT_ID}"
      OIDC_CLIENT_SECRET: "${OIDC_CLIENT_SECRET}"
      OIDC_ISSUER: "https://auth.example.com/realms/myrealm"

      # Optional: Timezone
      TZ: "America/New_York"
    volumes:
      # Config file (optional - can use env vars only)
      - ./config.yml:/app/config.yml:ro

      # Data directory (contains SQLite DB + app data)
      - mydia_data:/data

      # Media libraries (mount as many as needed)
      - /path/to/movies:/media/movies
      - /path/to/tv:/media/tv
    healthcheck:
      test: ["CMD", "/app/bin/mydia", "rpc", "Mydia.Health.check()"]
      interval: 30s
      timeout: 3s
      start_period: 10s
      retries: 3
    # Optional: limit resources
    deploy:
      resources:
        limits:
          memory: 512M
        reservations:
          memory: 256M

volumes:
  mydia_data:
    driver: local
```

### Simple Docker Run Example

For even simpler deployment:

```bash
docker run -d \
  --name mydia \
  -p 4000:4000 \
  -e SECRET_KEY_BASE="your-secret-key-here" \
  -e OIDC_CLIENT_ID="your-client-id" \
  -e OIDC_CLIENT_SECRET="your-client-secret" \
  -e OIDC_ISSUER="https://auth.example.com/realms/myrealm" \
  -v mydia_data:/data \
  -v /path/to/movies:/media/movies \
  -v /path/to/tv:/media/tv \
  --restart unless-stopped \
  mydia:latest
```

### Backup & Restore

Since SQLite uses a single file, backups are simple:

```bash
# Backup
docker exec mydia sqlite3 /config/mydia.db ".backup /data/backup.db"
docker cp mydia:/data/backup.db ./mydia-backup-$(date +%Y%m%d).db

# Restore
docker cp ./mydia-backup-20250101.db mydia:/data/restore.db
docker exec mydia mv /config/mydia.db /config/mydia.db.old
docker exec mydia mv /data/restore.db /config/mydia.db
docker restart mydia
```

## Security Considerations

### Authentication & Authorization
- OIDC tokens validated on every request
- Role-based access control (RBAC) for API endpoints
- API keys for service-to-service communication
- Rate limiting on authentication endpoints

### Data Security
- Secrets stored in environment variables, never in code
- Database file permissions restricted to application user
- API keys hashed in database (using Argon2)
- Audit logging for sensitive operations
- Optional: Encrypt SQLite database file at rest using SQLCipher extension

### Input Validation
- All user input sanitized and validated
- File paths restricted to configured directories
- SQL injection prevention via Ecto parameterized queries
- XSS prevention via Phoenix HTML escaping

## Performance Considerations

### Database Optimization (SQLite-Specific)
- **Indexes**: Created on frequently queried fields (tmdb_id, imdb_id, title, status)
- **WAL Mode**: Write-Ahead Logging enabled for concurrent reads during writes
- **PRAGMA Settings**:
  ```sql
  PRAGMA journal_mode = WAL;
  PRAGMA synchronous = NORMAL;
  PRAGMA cache_size = -64000;  -- 64MB cache
  PRAGMA temp_store = MEMORY;
  PRAGMA busy_timeout = 5000;  -- 5 second timeout
  PRAGMA foreign_keys = ON;
  ```
- **JSON1 Extension**: Efficient JSON queries using `json_extract()` and indexed JSON paths
- **Prepared Statements**: Ecto automatically uses prepared statements
- **Connection Pooling**: Limited pool size (1-2 connections) for SQLite's write serialization
- **Read-Heavy Optimization**: WAL mode allows unlimited concurrent readers

### Performance Limits
- **Concurrent Writes**: Serialized (one at a time) - acceptable for typical media management
- **Read Performance**: Excellent - multiple processes can read simultaneously
- **Database Size**: Tested up to 100GB+ (handles 50K+ media items comfortably)
- **Write Throughput**: ~2000-5000 inserts/sec in WAL mode

### Caching Strategy
- ETS tables for configuration and frequently accessed data
- Phoenix LiveView process-level caching
- CDN for static assets

### Scalability
- **Single Node**: SQLite works best on a single node (perfect for self-hosting)
- **Vertical Scaling**: Add more CPU/RAM to the single container
- **Background Jobs**: Oban efficiently distributes jobs across available cores
- **File Storage**: Network-attached storage (NFS, SMB) or object storage (S3) supported
- **High Availability**: For mission-critical deployments, switch to PostgreSQL for multi-node clustering

## Monitoring & Observability

### Metrics (Prometheus)
- HTTP request rates and latencies
- Background job queue depths
- Database connection pool usage
- Media library statistics

### Logging
- Structured JSON logging
- Log levels configurable per module
- Integration with syslog/journald
- Correlation IDs for request tracing

### Health Checks
- Database connectivity
- File system accessibility
- External service availability
- Background job processing status

## Development Environment

### Prerequisites
- Elixir 1.16+
- Erlang/OTP 26+
- SQLite3 (included with most systems)
- Node.js 18+ (for assets)

**Note**: No database server to install or configure!

### Key Dependencies

```elixir
# mix.exs
defp deps do
  [
    # Phoenix Framework
    {:phoenix, "~> 1.7"},
    {:phoenix_html, "~> 4.0"},
    {:phoenix_live_view, "~> 0.20"},
    {:phoenix_live_dashboard, "~> 0.8"},

    # Database
    {:ecto, "~> 3.11"},
    {:ecto_sql, "~> 3.11"},
    {:ecto_sqlite3, "~> 0.14"},  # SQLite adapter for Ecto

    # Background Jobs
    {:oban, "~> 2.17"},

    # Authentication
    {:ueberauth, "~> 0.10"},
    {:ueberauth_oidc, "~> 0.2"},
    {:guardian, "~> 2.3"},

    # HTTP Client
    {:finch, "~> 0.16"},
    {:req, "~> 0.4"},

    # JSON
    {:jason, "~> 1.4"},

    # Utilities
    {:uuid, "~> 1.1"},
    {:timex, "~> 3.7"},

    # Development
    {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
    {:dialyxir, "~> 1.4", only: [:dev], runtime: false}
  ]
end
```

### Local Setup

```bash
# Clone repository
git clone https://github.com/yourusername/mydia.git
cd mydia

# Install dependencies
mix deps.get
npm install --prefix assets

# Setup database (creates SQLite file and runs migrations)
mix ecto.setup

# Start development server
mix phx.server

# Or with IEx
iex -S mix phx.server
```

Visit http://localhost:4000 - the SQLite database will be created at `mydia_dev.db` in the project root.

### Testing Strategy
- Unit tests for business logic (Contexts)
- Integration tests for external services (Adapters)
- Controller/LiveView tests for UI
- End-to-end tests for critical workflows
- Property-based testing for complex logic

### CI/CD Pipeline
1. Lint (mix format --check-formatted, mix credo)
2. Type checking (dialyzer)
3. Tests (mix test)
4. Build Docker image
5. Security scanning
6. Deploy to staging
7. Smoke tests
8. Deploy to production

## Migration from *arr Stack

### Import Tools
- Import existing media library structure
- Parse *arr configuration for indexers and clients
- Map quality profiles to Mydia equivalents
- Preserve existing file organization

### Compatibility
- Monitor same folder structure as *arr apps
- Support same download client APIs
- Compatible webhook formats
- Import/export YAML configuration

## SQLite vs PostgreSQL Decision Matrix

### Use SQLite (Default) When:
- ✅ Self-hosting for personal use or small household
- ✅ Library size < 50,000 media items
- ✅ Single server deployment
- ✅ Simplicity and ease of deployment are priorities
- ✅ Regular backups via simple file copy
- ✅ Lower resource consumption needed

### Consider PostgreSQL When:
- ⚠️ Library size > 50,000 media items
- ⚠️ High concurrent user load (10+ simultaneous users)
- ⚠️ Multi-node deployment required
- ⚠️ Advanced replication needs
- ⚠️ Existing PostgreSQL infrastructure available

### Migration Path
The application supports both databases via configuration. To migrate from SQLite to PostgreSQL:

1. Export data via API or CLI tool
2. Update configuration to PostgreSQL
3. Run migrations
4. Import data
5. Verify and switch over

## Database Maintenance

### SQLite Maintenance Tasks

```bash
# Analyze query performance
docker exec -it mydia sqlite3 /config/mydia.db "ANALYZE;"

# Check database integrity
docker exec -it mydia sqlite3 /config/mydia.db "PRAGMA integrity_check;"

# Optimize (VACUUM) - reclaim space after deletes
docker exec -it mydia sqlite3 /config/mydia.db "VACUUM;"

# View database size
docker exec -it mydia sqlite3 /config/mydia.db "SELECT page_count * page_size / 1024 / 1024 AS size_mb FROM pragma_page_count(), pragma_page_size();"

# WAL checkpoint (consolidate WAL file into main database)
docker exec -it mydia sqlite3 /config/mydia.db "PRAGMA wal_checkpoint(FULL);"
```

### Automated Maintenance

Oban background jobs will handle:
- Daily ANALYZE for query optimization
- Weekly VACUUM during low-activity periods
- WAL checkpoint management
- Integrity checks with alerting
