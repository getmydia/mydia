# Mydia Download & Media Import Infrastructure - Architecture Analysis

## Executive Summary

Mydia uses a **protocol-agnostic adapter pattern** for downloads and indexers. The system is designed to support multiple download protocols (torrent, HTTP, etc.) and indexers through consistent interfaces. This document outlines the current architecture and how Usenet support can be cleanly integrated.

---

## 1. Download Infrastructure

### 1.1 Current Download Protocols

The system currently supports:
1. **qBittorrent** - Torrent protocol via Web API
2. **Transmission** - Torrent protocol via RPC API
3. **HTTP** - Direct file downloads

### 1.2 Download Client Architecture

**Location:** `lib/mydia/downloads/`

#### Behavior Pattern: `Mydia.Downloads.Client`
File: `lib/mydia/downloads/client.ex`

Defines the interface all download adapters must implement:

```elixir
@callback test_connection(config :: map()) :: {:ok, map()} | {:error, Error.t()}
@callback add_torrent(config, torrent_input, opts) :: {:ok, client_id} | {:error, Error.t()}
@callback get_status(config, client_id) :: {:ok, status_map} | {:error, Error.t()}
@callback list_torrents(config, opts) :: {:ok, [status_map]} | {:error, Error.t()}
@callback remove_torrent(config, client_id, opts) :: :ok | {:error, Error.t()}
@callback pause_torrent(config, client_id) :: :ok | {:error, Error.t()}
@callback resume_torrent(config, client_id) :: :ok | {:error, Error.t()}
```

**Key Types:**

```elixir
@type torrent_input :: {:magnet, String.t()} | {:file, binary()} | {:url, String.t()}

@type torrent_state :: 
  :downloading | :seeding | :paused | :error | :completed | :checking

@type status_map :: %{
  id: String.t(),
  name: String.t(),
  state: torrent_state(),
  progress: float(),
  download_speed: non_neg_integer(),
  upload_speed: non_neg_integer(),
  downloaded: non_neg_integer(),
  uploaded: non_neg_integer(),
  size: non_neg_integer(),
  eta: non_neg_integer() | nil,
  ratio: float(),
  save_path: String.t(),
  added_at: DateTime.t(),
  completed_at: DateTime.t() | nil
}
```

#### Implementations

1. **qBittorrent:** `lib/mydia/downloads/client/qbittorrent.ex`
   - Uses Web API with cookie-based authentication
   - Maps qBittorrent states to internal states
   - Supports torrent file, magnet links, and URL inputs

2. **Transmission:** `lib/mydia/downloads/client/transmission.ex`
   - Uses RPC API
   - Similar state mapping

3. **HTTP Client:** `lib/mydia/downloads/client/http.ex`
   - Shared utilities for all adapters
   - Handles authentication (basic auth, cookies, tokens)
   - Request/response management using Req library

#### Client Registry

File: `lib/mydia/downloads/client/registry.ex`

Maps download types to adapter modules:

```elixir
def register(type, module) do
  # Register adapter modules by type
end
```

Called during app startup in `lib/mydia/downloads.ex`:

```elixir
def register_clients do
  Registry.register(:qbittorrent, Mydia.Downloads.Client.Qbittorrent)
  Registry.register(:transmission, Mydia.Downloads.Client.Transmission)
end
```

### 1.3 Configuration System

**Location:** `lib/mydia/settings/download_client_config.ex`

Database schema for download client configurations:

```elixir
schema "download_client_configs" do
  field :name, :string
  field :type, Ecto.Enum, values: [:qbittorrent, :transmission, :http]
  field :enabled, :boolean, default: true
  field :priority, :integer, default: 1
  field :host, :string
  field :port, :integer
  field :use_ssl, :boolean, default: false
  field :url_base, :string
  field :username, :string
  field :password, :string
  field :api_key, :string
  field :category, :string
  field :download_directory, :string
  field :connection_settings, :map
  
  belongs_to :updated_by, Mydia.Accounts.User
  timestamps(type: :utc_datetime)
end
```

**Client Selection Flow:**

1. User initiates search (movie/tv show)
2. Search results returned from indexer
3. `Downloads.initiate_download(search_result, opts)` called
4. `select_download_client(opts)` picks client by:
   - Specific client name if provided
   - Otherwise: highest priority enabled client
5. Adapter module loaded for client type
6. Torrent added to client via adapter

### 1.4 Download Queue Management

**Location:** `lib/mydia/downloads.ex`

Core functions:

```elixir
# List downloads with real-time status from clients
def list_downloads_with_status(opts)

# Get single download
def get_download!(id, opts)

# Create download record
def create_download(attrs)

# Mark as completed
def mark_download_completed(download)

# Mark as failed
def mark_download_failed(download, error_message)

# Pause/resume downloads
def pause_download(download, opts)
def resume_download(download, opts)

# Cancel download
def cancel_download(download, opts)

# Initiate download from search result
def initiate_download(search_result, opts)
```

**Database Schema:** `lib/mydia/downloads/download.ex`

```elixir
schema "downloads" do
  field :indexer, :string
  field :title, :string
  field :download_url, :string
  field :download_client, :string
  field :download_client_id, :string  # Client's internal ID
  field :completed_at, :utc_datetime
  field :error_message, :string
  field :metadata, :map

  belongs_to :media_item, Mydia.Media.MediaItem
  belongs_to :episode, Mydia.Media.Episode

  timestamps(type: :utc_datetime, updated_at: :updated_at)
end
```

**Key Design Points:**

- Downloads table is **ephemeral** (active downloads only)
- Real-time status comes from clients, not DB
- Download records deleted after successful import
- Metadata field stores protocol-specific info (season pack info, etc.)

---

## 2. Download Monitoring & Import Jobs

### 2.1 Download Monitor Job

**File:** `lib/mydia/jobs/download_monitor.ex`

Background job running on schedule (via Oban):

**Responsibilities:**
1. Poll all download clients for status changes
2. Detect newly completed downloads
3. Detect failed downloads
4. Detect manually removed downloads
5. Enqueue MediaImport jobs for completed downloads
6. Track events

**State Mapping Logic:**
```elixir
completed =
  Enum.filter(downloads, fn d ->
    d.status in ["completed", "seeding"] and is_nil(d.db_completed_at)
  end)

failed = Enum.filter(downloads, &(&1.status == "failed" and is_nil(&1.error_message)))

missing =
  Enum.filter(downloads, fn d ->
    d.status == "missing" and is_nil(d.db_completed_at) and is_nil(&d.error_message)
  end)
```

**Event Tracking:**
- `Events.download_completed/2`
- `Events.download_failed/2`
- Activity feed updates

### 2.2 Media Import Job

**File:** `lib/mydia/jobs/media_import.ex`

Handles file organization and library integration:

**Responsibilities:**
1. Locate downloaded files from client
2. Filter video files only
3. Parse filenames for metadata
4. Determine destination paths (movie/TV structure)
5. Analyze files with FFprobe
6. Create media_file records with metadata
7. Handle conflicts and errors
8. Optionally clean up from download client
9. Delete download record after successful import

**File Operations Priority:**
```elixir
# 1. Hardlink (instant, no duplicate storage) - requires same filesystem
# 2. Move (when use_hardlinks=false and move_files=true)
# 3. Copy (default, safest option)
```

**Destination Paths:**

Movies: `{library_root}/{Title} ({Year})/`
TV Shows: `{library_root}/{Show Title}/Season NN/`

**Metadata Enrichment:**
- Filename parsing: resolution, codec, audio, source, release group
- FFprobe analysis: actual resolution, codec, audio codec, bitrate, HDR
- Merges filename + file analysis

---

## 3. Indexer Infrastructure

### 3.1 Indexer Adapter Behavior

**Location:** `lib/mydia/indexers/adapter.ex`

Similar pattern to download clients:

```elixir
@callback test_connection(config) :: {:ok, map()} | {:error, Error.t()}
@callback search(config, query, opts) :: {:ok, [SearchResult]} | {:error, Error.t()}
@callback get_capabilities(config) :: {:ok, capabilities_map} | {:error, Error.t()}
```

**Current Implementations:**
- Prowlarr: `lib/mydia/indexers/adapter/prowlarr.ex`
- Jackett: `lib/mydia/indexers/adapter/jackett.ex`

### 3.2 Search Results

**File:** `lib/mydia/indexers/search_result.ex`

Normalized search result structure:

```elixir
@type t :: %SearchResult{
  title: String.t(),
  size: non_neg_integer(),
  seeders: non_neg_integer(),
  leechers: non_neg_integer(),
  download_url: String.t(),  # Magnet link, NZB URL, etc.
  info_url: String.t() | nil,
  indexer: String.t(),
  category: integer() | nil,
  published_at: DateTime.t() | nil,
  quality: quality_info() | nil,
  metadata: map() | nil
}

@type quality_info :: %{
  resolution: String.t() | nil,
  source: String.t() | nil,
  codec: String.t() | nil,
  audio: String.t() | nil,
  hdr: boolean(),
  proper: boolean(),
  repack: boolean()
}
```

### 3.3 Release Ranking

**File:** `lib/mydia/indexers/release_ranker.ex`

Selects best result from multiple search results based on:
- Quality profile preferences
- Size constraints
- Seeder health
- Release tags (PROPER, REPACK)
- Preferred/blocked tags

---

## 4. Search Job Architecture

### 4.1 Movie Search Job

**File:** `lib/mydia/jobs/movie_search.ex`

Modes:
1. **"all_monitored"** - Search all monitored movies without files (scheduled)
2. **"specific"** - Search single movie by ID (UI-triggered)

**Flow:**
1. Find monitored movies without media files
2. Build search query (title + year)
3. Search all indexers via `Indexers.search_all()`
4. Rank results with quality preferences
5. Select best result
6. Call `Downloads.initiate_download()`

### 4.2 TV Show Search Job

**File:** `lib/mydia/jobs/tv_show_search.ex`

Modes:
1. **"specific"** - Single episode
2. **"season"** - Full season (prefer season pack)
3. **"show"** - All episodes with smart logic
4. **"all_monitored"** - All monitored episodes (scheduled)

**Smart Season Pack Logic:**

For "show" and "all_monitored" modes:
- Group episodes by season
- Calculate missing percentage per season
- If >= 70% missing → prefer season pack
- If < 70% missing → download individual episodes

**Season Pack Download:**

When initiating season pack download, metadata is stored:

```elixir
metadata = %{
  season_pack: true,
  season_number: season_number,
  episode_count: length(episodes),
  episode_ids: Enum.map(episodes, & &1.id)
}

result_with_metadata = Map.put(result, :metadata, metadata)
Downloads.initiate_download(result_with_metadata, media_item_id: media_item.id)
```

The import job later uses this metadata to map files to individual episodes.

---

## 5. Metadata Management

### 5.1 Metadata Enricher

**File:** `lib/mydia/library/metadata_enricher.ex`

When a media item is discovered:
1. Match against provider (TMDB)
2. Fetch full metadata
3. Download images (poster, backdrop)
4. For TV shows: fetch and create episode records
5. Store all metadata

### 5.2 File Analysis

**File:** `lib/mydia/library/file_analyzer.ex`

Uses FFprobe to extract:
- Resolution
- Video codec
- Audio codec
- Bitrate
- HDR format
- Duration
- Subtitle streams

Merges with filename parsing for complete metadata.

---

## 6. Data Flow Example: Movie Download

```
[User initiates search]
         ↓
[MovieSearch job]
  - Build query: "Movie Title (2024)"
  - Indexers.search_all()
  - ReleaseRanker.select_best_result()
         ↓
[Downloads.initiate_download(search_result, media_item_id: 123)]
  - select_download_client() → get highest priority enabled client
  - Client adapter: Mydia.Downloads.Client.Qbittorrent
  - add_torrent() → returns client_id
  - create_download_record() → insert into downloads table
  - Events.download_initiated()
         ↓
[DownloadMonitor job (polling)]
  - list_downloads_with_status() → queries all clients
  - Detects status change to "completed" or "seeding"
  - handle_completion() → marks completed_at
  - Events.download_completed()
  - Enqueue MediaImport job
         ↓
[MediaImport job]
  - Locate files in client's save_path
  - Parse filenames
  - Analyze files with FFprobe
  - Determine destination: /library/Movie Title (2024)/
  - Hardlink/copy files
  - Create media_file records
  - Delete download record
         ↓
[Library now contains media file]
```

---

## 7. Integration Points for Usenet Support

### 7.1 Required New Adapter

**Module:** `lib/mydia/downloads/client/usenet.ex`

Must implement `Mydia.Downloads.Client` behavior:

```elixir
defmodule Mydia.Downloads.Client.Usenet do
  @behaviour Mydia.Downloads.Client

  @impl true
  def test_connection(config) do
    # Connect to SABnzbd/NZBGet/etc. and verify auth
    # Return {:ok, %{version: "...", api_version: "..."}} or error
  end

  @impl true
  def add_torrent(config, torrent_input, opts) do
    # torrent_input will be {:url, "http://indexer.com/file.nzb"}
    # Download NZB file or use URL directly
    # Submit to Usenet client
    # Return {:ok, client_id} or error
  end

  @impl true
  def get_status(config, client_id) do
    # Query Usenet client for download status
    # Return status_map with standard fields
  end

  @impl true
  def list_torrents(config, opts) do
    # List all downloads from Usenet client
    # Return list of status_maps
  end

  @impl true
  def remove_torrent(config, client_id, opts) do
    # Remove download from Usenet client
    # Return :ok or error
  end

  @impl true
  def pause_torrent(config, client_id) do
    # Pause download
    # Return :ok or error
  end

  @impl true
  def resume_torrent(config, client_id) do
    # Resume download
    # Return :ok or error
  end
end
```

### 7.2 Configuration Update

Update `DownloadClientConfig` schema to support Usenet:

```elixir
@client_types [:qbittorrent, :transmission, :http, :usenet]

# Already supports:
# :host - SABnzbd/NZBGet host
# :port - SABnzbd/NZBGet port
# :api_key - API key for authentication
# :username - Basic auth (if needed)
# :password - Basic auth (if needed)
# :connection_settings - Protocol-specific options
```

### 7.3 Registry Update

In `lib/mydia/downloads.ex`:

```elixir
def register_clients do
  Registry.register(:qbittorrent, Mydia.Downloads.Client.Qbittorrent)
  Registry.register(:transmission, Mydia.Downloads.Client.Transmission)
  Registry.register(:usenet, Mydia.Downloads.Client.Usenet)  # NEW
  
  Logger.info("Download client adapter registration complete")
  :ok
end
```

### 7.4 Indexer Support for NZB

Usenet providers (Prowlarr, Jackett) return NZB URLs in search results:

```elixir
%SearchResult{
  title: "Movie Title 1080p",
  download_url: "http://indexer.com/file.nzb",  # NZB URL
  # ... other fields
}
```

**No indexer changes needed** - they already return download URLs.

### 7.5 State Mapping

Usenet client states → internal states:

Common states in SABnzbd/NZBGet:
- "queued" → `:downloading`
- "downloading" → `:downloading`
- "paused" → `:paused`
- "completed" → `:completed`
- "failed" → `:error`

Implement state mapping in Usenet adapter similar to Qbittorrent.

### 7.6 Media Import Compatibility

**No changes needed** - MediaImport job is client-agnostic:

1. Gets download record (client-agnostic)
2. Queries client for file location via `Client.get_status()`
3. Lists files in save_path
4. Processes files (parsing, analysis, import)

Usenet adapter must return `save_path` in status_map pointing to:
- Single file for NZB with one release
- Directory for multi-file NZBs

### 7.7 HTTP Client Library

The shared `Mydia.Downloads.Client.HTTP` module handles:
- URL building (http/https)
- Authentication (basic, API key, custom headers)
- Request/response with Req
- Error handling

Usenet adapters should use this for API calls to SABnzbd/NZBGet.

---

## 8. Key Design Patterns

### 8.1 Adapter Pattern

- **Client Behavior:** `Mydia.Downloads.Client`
- **Indexer Behavior:** `Mydia.Indexers.Adapter`
- **Registry:** Maps type atoms to module implementations
- **Benefits:** Pluggable implementations, no coupling to specific protocols

### 8.2 Stateless Client Status

- Download records store only metadata (title, URL, media associations)
- Real-time status fetched from clients on demand
- No status polling/caching in DB
- Reduces complexity, single source of truth

### 8.3 Ephemeral Download Queue

- Downloads deleted after successful import
- Library is source of truth for media
- Only active downloads kept in DB

### 8.4 Metadata Storage

- Downloads table has `metadata: :map` field
- Used for protocol-specific info (season pack markers)
- Also used for import hints (hardlink enabled, etc.)

### 8.5 File Organization Post-Import

- Standardized paths: Movies/{Title} ({Year})/
- TV shows: {Title}/Season NN/
- Metadata embedded in media_file records

---

## 9. Configuration Flow

```
Admin Interface
      ↓
Create DownloadClientConfig
  - name: "SABnzbd"
  - type: :usenet (new)
  - host: "localhost"
  - port: 8080
  - api_key: "..."
      ↓
Stored in download_client_configs table
      ↓
Settings.get_runtime_config() loads all configs
      ↓
When initiating download:
  select_download_client() → finds by name or priority
  get_adapter_for_client() → retrieves Mydia.Downloads.Client.Usenet
  config_to_map() → converts schema to map for adapter
  adapter.add_torrent() → called with NZB URL
```

---

## 10. Testing Strategy for Usenet Support

### 10.1 Unit Tests

- Mock Usenet client API responses
- Test state mapping logic
- Test error handling

### 10.2 Integration Tests

- Test with real SABnzbd/NZBGet instance (Docker)
- Test download initiation flow
- Test file import from Usenet downloads

### 10.3 End-to-End Tests

- Search → Download → Monitor → Import pipeline
- Cross-protocol (torrent + Usenet)

---

## 11. Performance Considerations

### 11.1 Status Polling

Current system polls all clients each monitor cycle:

```elixir
def list_downloads_with_status(opts) do
  downloads = list_downloads(preload: [:media_item, episode: :media_item])
  clients = get_configured_clients()
  client_statuses = fetch_all_client_statuses(clients)  # One call per client
  
  downloads
  |> Enum.map(&enrich_download_with_status(&1, client_statuses))
end
```

- **Parallel execution:** Each client query could be parallelized with `Task.async_stream()`
- **Caching:** Status could be cached for short periods
- **Usenet consideration:** SABnzbd/NZBGet APIs are fast; minimal impact

### 11.2 File Analysis

FFprobe calls are made per-file during import:

```elixir
file_metadata =
  case FileAnalyzer.analyze(path) do
    {:ok, metadata} -> metadata
    {:error, _} -> fallback_to_filename_parse()
  end
```

- Sequential analysis is acceptable for typical imports
- Could be parallelized with `Task.async_stream()` for large downloads

---

## 12. Known Limitations & Future Extensions

### 12.1 Current Limitations

1. **Single indexer type per search** - No mixing Prowlarr + Jackett in same search
2. **Quality profiles** - Limited integration with custom formats
3. **Season pack limitations** - Fixed 70% threshold (not configurable)

### 12.2 Usenet-Specific Considerations

1. **NZB file handling**
   - SABnzbd/NZBGet download NZB and parse internally
   - File paths not available until download starts
   - May need special handling in MediaImport for NZB metadata

2. **Multipart files**
   - Usenet downloads often result in multiple files (RAR archives, etc.)
   - MediaImport already filters for video extensions only
   - Consider adding RAR/7z extraction for completeness

3. **Rate limiting**
   - Usenet API endpoints typically have lower rate limits
   - Consider implementing rate limiter similar to indexer rate limiter
   - See: `lib/mydia/indexers/rate_limiter.ex`

---

## Summary

Usenet support requires:

1. **New adapter module** implementing `Mydia.Downloads.Client` behavior
2. **Configuration type** added to `DownloadClientConfig` schema
3. **Registry entry** for type `:usenet`
4. **API client** for SABnzbd/NZBGet (can use shared `HTTP` module)
5. **State mapping** from Usenet states to internal states
6. **No changes to indexers, search jobs, or import jobs**

The architecture is cleanly extensible - Usenet integrates as a "download provider" alongside torrents with zero impact on search, import, or media management logic.

