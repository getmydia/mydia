# Architecture

Overview of Mydia's system architecture and design decisions.

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
