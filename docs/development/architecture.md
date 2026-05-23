# Architecture

Overview of Mydia's system architecture and design decisions.

## Two backends, one repository

Mydia ships two backends from the same Git repository: the original Phoenix/Elixir backend in `lib/` and a Rust reimplementation in `mydia-rs/`. Both read and write the same database, the same on-disk media, and the same metadata-relay service. Both expose the same GraphQL contract for the Flutter player and the same REST API surface for paired remote devices. Self-hosters pick which backend they run by choosing a Docker image tag.

| Backend | Code | Docker image (SQLite) | Docker image (Postgres) |
|---|---|---|---|
| Phoenix | `lib/` | `ghcr.io/getmydia/mydia:latest` | `ghcr.io/getmydia/mydia:latest-pg` |
| Rust (mydia-rs) | `mydia-rs/` | `ghcr.io/getmydia/mydia/mydia-rs:latest` | (same image) |

mydia-rs links both sqlx drivers into one binary and picks the engine at runtime via `database.type`. The Phoenix split exists because Ecto's adapter is compiled into the BEAM release; that constraint is gone on the Rust side.

The two backends coexist on master. Every push publishes both images. Phoenix retains migration ownership: the schema source of truth is `priv/repo/migrations/` and mydia-rs never writes a migration. mydia-rs probes `schema_migrations` at startup and refuses to start against a database older than what its binary expects; if the database is newer, it logs a warning and continues.

The Flutter player works against either backend unchanged. The GraphQL contract is frozen and snapshot-tested via a parity replay harness against captured player sessions.

During the parallel window:

- Cutover is a Docker tag change. See [Cutting over from Phoenix to mydia-rs](../operators/cutover-to-mydia-rs.md).
- Rollback is a Docker tag change in reverse. See [Rolling back from mydia-rs to Phoenix](../operators/rollback-to-phoenix.md).
- Operators should not run both backends at the same time. mydia-rs enforces this with a database advisory lock; Phoenix does not yet have a symmetric guard.

The Rust workspace lives at `mydia-rs/Cargo.toml` and is split into per-domain crates: `app` (binary), `config`, `db`, `models`, `auth`, `web` (Dioxus full-stack UI + REST API), `graphql` (async-graphql), `jobs` (apalis), `pubsub`, `library`, `downloads`, `indexers`, `metadata`, `streaming`, `subtitles`, `p2p`, `events`, `integrations`, `parity-harness`. The shared p2p networking core (`native/mydia_p2p_core`) is a Cargo path dependency consumed by both backends (via Rustler from Phoenix, directly from `crates/p2p` on the Rust side, and via `flutter_rust_bridge` from the Flutter player).

The rest of this page documents the Phoenix backend as it stands today. mydia-rs mirrors the same surface; for crate-level layout and dev-loop notes, see [`mydia-rs/README.md`](https://github.com/getmydia/mydia/blob/master/mydia-rs/README.md).

## Technology Stack

- **Phoenix 1.8** - Web framework with LiveView
- **Elixir** - Functional programming language on BEAM VM
- **Ecto** - Database wrapper and query generator
- **SQLite/PostgreSQL** - Database options
- **Oban** - Background job processing
- **Tailwind CSS + DaisyUI** - Styling
- **Req** - HTTP client

## System Overview

```
┌─────────────────────────────────────────────────────────────┐
│                        Mydia                                 │
├─────────────────────────────────────────────────────────────┤
│  Web Layer (Phoenix LiveView)                               │
│  ├─ LiveViews - Real-time UI                                │
│  ├─ Controllers - API endpoints                             │
│  └─ Components - Reusable UI elements                       │
├─────────────────────────────────────────────────────────────┤
│  Business Logic                                             │
│  ├─ Libraries - Media organization                          │
│  ├─ Downloads - Download management                         │
│  ├─ Indexers - Search integration                           │
│  └─ Metadata - External data fetching                       │
├─────────────────────────────────────────────────────────────┤
│  Background Jobs (Oban)                                     │
│  ├─ Media scanning                                          │
│  ├─ Download monitoring                                     │
│  └─ Metadata fetching                                       │
├─────────────────────────────────────────────────────────────┤
│  Data Layer (Ecto)                                          │
│  └─ SQLite / PostgreSQL                                     │
└─────────────────────────────────────────────────────────────┘
          │                    │                    │
          ▼                    ▼                    ▼
    ┌──────────┐        ┌──────────┐        ┌──────────┐
    │ Download │        │ Indexers │        │ Metadata │
    │ Clients  │        │ (Prowlarr│        │  Relay   │
    │(qBit,etc)│        │ Jackett) │        │ Service  │
    └──────────┘        └──────────┘        └──────────┘
```

## Key Components

### Web Layer

Phoenix LiveView provides real-time updates without writing JavaScript:

- **Server-rendered HTML** - Initial page load
- **WebSocket connection** - Real-time updates
- **LiveComponents** - Reusable stateful components

### Business Logic

Organized into contexts following Phoenix conventions:

- `Mydia.Libraries` - Library and media management
- `Mydia.Downloads` - Download client integration
- `Mydia.Indexers` - Indexer search and configuration
- `Mydia.Accounts` - User authentication

### Background Jobs

Oban handles async tasks:

- **MediaScanWorker** - Scans library directories
- **DownloadMonitorWorker** - Monitors download progress
- **MetadataWorker** - Fetches external metadata

### Data Layer

Ecto schemas define the data model:

- **Movie/Series** - Media items
- **MediaFile** - Physical files
- **Download** - Download queue entries
- **QualityProfile** - Quality preferences

## External Integrations

### Metadata Relay

A companion service that:

- Proxies metadata requests to TVDB/TMDB
- Protects API keys
- Reduces rate limiting issues

### Download Clients

Adapter pattern for different clients:

- qBittorrent (HTTP API)
- Transmission (RPC)
- SABnzbd (HTTP API)
- NZBGet (JSON-RPC)

### Indexers

Integration with:

- Prowlarr (unified indexer management)
- Jackett (indexer proxy)
- Cardigann (native indexer definitions)

## Key Design Decisions

### LiveView Over SPA

Benefits:

- Simpler development (no separate frontend)
- Real-time by default
- SEO-friendly
- Reduced complexity

### SQLite Default

Benefits:

- Zero configuration
- Single-file backup
- Sufficient for personal use
- PostgreSQL available for scaling

### Relative Path Storage

Media files stored with relative paths:

- Portable database
- Easy library relocation
- No path updates needed

### Oban for Jobs

Benefits:

- Persistent job queue
- Automatic retries
- Monitoring/visibility
- Transaction-safe

## Directory Structure

```
lib/
├── mydia/
│   ├── accounts/          # User management
│   ├── downloads/         # Download logic
│   ├── indexers/          # Indexer integration
│   ├── libraries/         # Media management
│   ├── media/             # Media files
│   ├── metadata/          # External metadata
│   └── quality/           # Quality profiles
└── mydia_web/
    ├── components/        # UI components
    ├── controllers/       # HTTP controllers
    ├── live/              # LiveView modules
    └── layouts/           # Page layouts
```

## Data Flow Examples

### Adding Media

```
User searches → Indexer query → Results displayed
User selects → Download queued → Client notified
Download completes → File scanned → Media imported
Metadata fetched → Library updated → UI refreshed
```

### Library Scan

```
Scheduler triggers → Worker spawned
Directory walked → Files analyzed
Metadata matched → Database updated
Changes published → LiveViews refresh
```

## Scalability

### Single Instance (Default)

- SQLite database
- Sufficient for thousands of media items
- Handles multiple concurrent users

### Scaled Deployment

- PostgreSQL for database
- Multiple Mydia instances
- Load balancer (sticky sessions)
- Shared filesystem

## Contributing

See [Development Setup](setup.md) for environment configuration.

Key areas for contribution:

- New download client adapters
- Additional indexer support
- UI improvements
- Documentation
