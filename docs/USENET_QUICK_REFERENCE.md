# Usenet Support - Quick Reference Guide

## File Locations & Key Modules

### Download Client System
```
lib/mydia/downloads/
├── client.ex                          # Behavior definition
├── client/
│   ├── qbittorrent.ex                # Torrent adapter
│   ├── transmission.ex                # Torrent adapter
│   ├── http.ex                        # Shared HTTP utilities
│   ├── error.ex                       # Error types
│   └── registry.ex                    # Adapter registration
├── download.ex                        # Database schema
├── downloads.ex                       # Context functions
├── client_health.ex                   # Client monitoring
└── untracked_matcher.ex              # Manual torrent detection
```

### Settings Configuration
```
lib/mydia/settings/
└── download_client_config.ex          # Config schema (needs :usenet type)
```

### Import Jobs
```
lib/mydia/jobs/
├── download_monitor.ex                # Status polling
├── media_import.ex                    # File organization
├── movie_search.ex                    # Movie search
└── tv_show_search.ex                  # TV search
```

### Indexers
```
lib/mydia/indexers/
├── adapter.ex                         # Behavior definition
├── search_result.ex                   # Normalized results
├── adapter/
│   ├── prowlarr.ex                   # Returns NZB URLs
│   └── jackett.ex                    # Returns NZB URLs
└── release_ranker.ex                 # Quality selection
```

---

## Adapter Implementation Checklist

### Step 1: Create `lib/mydia/downloads/client/usenet.ex`

```elixir
defmodule Mydia.Downloads.Client.Usenet do
  @behaviour Mydia.Downloads.Client
  require Logger
  
  alias Mydia.Downloads.Client.{Error, HTTP}
  
  # Implement 7 callbacks:
  # - test_connection/1
  # - add_torrent/3          ← receives {:url, "file.nzb"}
  # - get_status/2           ← returns status_map with save_path
  # - list_torrents/2
  # - remove_torrent/3
  # - pause_torrent/2
  # - resume_torrent/2
end
```

### Step 2: Update Configuration Schema

File: `lib/mydia/settings/download_client_config.ex`

```elixir
@client_types [:qbittorrent, :transmission, :http, :usenet]  # Add :usenet
```

### Step 3: Register Adapter

File: `lib/mydia/downloads.ex` (in `register_clients/0`)

```elixir
Registry.register(:usenet, Mydia.Downloads.Client.Usenet)
```

### Step 4: Create Tests

```
test/mydia/downloads/client/usenet_test.exs
```

---

## Client-Specific Implementation Details

### SABnzbd Example

**API Endpoint:** `http://host:port/api`

**Connection Test:**
```
GET /api?mode=version&output=json
```

**Add Download:**
```
POST /api?mode=addurl&name={nzb_url}&output=json
Returns: {nzb_id}
```

**Get Status:**
```
GET /api?mode=queuedetails&output=json
Parse queue_detail[].nzo_id, etc_time_left, status, size, downloaded
```

**State Mapping:**
- "Downloading" → `:downloading`
- "Paused" → `:paused`
- "Completed" → `:completed`
- "Failed" → `:error`

### NZBGet Example

**API Endpoint:** `http://host:port/api`

**Connection Test:**
```
POST /api
json: {"method": "version", "params": {}}
```

**Add Download:**
```
POST /api
json: {"method": "append", "params": {"filename": "{nzb_url}", "url": true}}
```

**Get Status:**
```
POST /api
json: {"method": "listgroups", "params": {}}
Parse groups[].id, status, etc_time, size_all, size_lo_pp
```

---

## Torrent Input Types (Reuse Existing)

When download is initiated from indexer search:

```elixir
search_result = %SearchResult{
  download_url: "https://indexer.example.com/file.nzb",
  # ... other fields
}

Downloads.initiate_download(search_result, media_item_id: 123)
```

**Adapter receives:**
```elixir
add_torrent(config, {:url, "https://indexer.example.com/file.nzb"}, opts)
```

Your adapter should:
1. Download NZB file from URL (or pass to client)
2. Add to Usenet client
3. Return client_id

---

## Status Map Structure (Required)

All adapters must return this structure:

```elixir
%{
  id: "nzb_id_from_client",                    # Used for pause/resume/delete
  name: "Release.Title",                       # Display name
  state: :downloading,                         # :downloading|:paused|:completed|:error
  progress: 65.5,                              # 0.0-100.0
  download_speed: 5_000_000,                   # bytes/sec
  upload_speed: 0,                             # N/A for Usenet, set to 0
  downloaded: 650_000_000,                     # bytes
  uploaded: 0,                                 # bytes
  size: 1_000_000_000,                         # total bytes
  eta: 100,                                    # seconds remaining
  ratio: 0.0,                                  # N/A for Usenet, set to 0
  save_path: "/downloads/Release.Title",       # CRITICAL: where files are
  added_at: ~U[2024-01-01 12:00:00Z],         # DateTime
  completed_at: nil                            # DateTime or nil
}
```

**Critical fields for media import:**
- `id` - used to query this download again
- `state` - determines if download is done
- `save_path` - MediaImport job looks here for files
- `completed_at` - when download finished

---

## State Transition Flow

```
Initial State: :downloading
       ↓
DownloadMonitor polls every 60 seconds
       ↓
Adapter.get_status(config, client_id) returns status_map
       ↓
DownloadMonitor checks status_map.state
       ↓
state = :completed → handle_completion()
  ├─ mark_download_completed()
  ├─ Events.download_completed()
  └─ Enqueue MediaImport job
       ↓
MediaImport queries get_status() again
  └─ Uses save_path to find files
       ↓
Files imported, download record deleted
```

---

## HTTP Client Utilities (Reuse)

File: `lib/mydia/downloads/client/http.ex`

```elixir
# Create authenticated request
req = HTTP.new_request(config)

# GET request
{:ok, response} = HTTP.get(req, "/api/v2/version")

# POST request with JSON
{:ok, response} = HTTP.post(req, "/api", json: %{method: "version"})

# POST with form data
{:ok, response} = HTTP.post(req, "/api", form: %{mode: "version"})

# Error handling
case HTTP.get(req, "/api") do
  {:ok, response} -> handle_response(response)
  {:error, error} -> handle_error(error)
end
```

**Configuration passed to HTTP utilities:**
```elixir
config = %{
  host: "localhost",
  port: 8080,
  username: "admin",
  password: "secret",
  use_ssl: false,
  api_key: nil,
  options: %{timeout: 30_000, connect_timeout: 5_000}
}
```

---

## Testing Strategy

### Unit Test Template

```elixir
defmodule Mydia.Downloads.Client.UsenetTest do
  use ExUnit.Case
  
  describe "test_connection/1" do
    test "returns version info on successful connection" do
      # Mock API response
      # Call test_connection(config)
      # Assert {:ok, %{version: _}} returned
    end
    
    test "returns error on connection failure" do
      # Mock API 500 response
      # Assert {:error, error} returned
    end
  end
  
  describe "add_torrent/3" do
    test "downloads NZB and returns client_id" do
      # Mock HTTP GET for NZB download
      # Mock API POST for add download
      # Call add_torrent(config, {:url, "http://..."}, [])
      # Assert {:ok, "nzb_id"} returned
    end
  end
  
  describe "get_status/2" do
    test "returns current download status" do
      # Mock API response with queue details
      # Call get_status(config, "nzb_id")
      # Assert status_map returned with correct state
    end
    
    test "maps Usenet states to internal states" do
      # "Downloading" → :downloading
      # "Paused" → :paused
      # "Completed" → :completed
      # "Failed" → :error
    end
  end
  
  # Similar tests for pause, resume, remove, list
end
```

### Integration Test Template

```elixir
# Start SABnzbd/NZBGet in Docker
# Test actual API calls
# Test state transitions
# Test with real NZB files
```

---

## Debugging Tips

### Common Issues

1. **Status mapping wrong**
   - Check Usenet client API docs for actual state strings
   - Log raw API responses
   - Compare with qBittorrent adapter for pattern

2. **Files not found after download completes**
   - Verify save_path returned from get_status()
   - Check if NZB unpacks to directory vs single file
   - Handle both cases in save_path

3. **Client not connecting**
   - Verify host/port/auth in config
   - Check timeout settings
   - Log HTTP request/response

4. **State polling missing updates**
   - Ensure list_torrents() returns all states
   - Check filter parameters
   - Verify progress calculation

### Logging

```elixir
require Logger

Logger.info("Adding NZB", url: nzb_url)
Logger.debug("API Response", status: response.status, body: response.body)
Logger.error("Failed to parse response", error: error)
```

---

## Integration Points Overview

```
┌─────────────────────────────────────────────┐
│  Search Results (Prowlarr/Jackett)          │
│  Returns: NZB URLs                          │
└─────────────────────────────────────────────┘
          ↓
┌─────────────────────────────────────────────┐
│  ReleaseRanker                              │
│  Selects best result                        │
└─────────────────────────────────────────────┘
          ↓
┌─────────────────────────────────────────────┐
│  Downloads.initiate_download()              │
│  ├─ select_download_client()                │
│  ├─ Client.Usenet.add_torrent()   [NEW]    │
│  └─ create_download_record()                │
└─────────────────────────────────────────────┘
          ↓
┌─────────────────────────────────────────────┐
│  DownloadMonitor (polling)                  │
│  ├─ Client.Usenet.list_torrents()  [NEW]   │
│  ├─ Client.Usenet.get_status()     [NEW]   │
│  └─ Enqueue MediaImport                    │
└─────────────────────────────────────────────┘
          ↓
┌─────────────────────────────────────────────┐
│  MediaImport Job                            │
│  ├─ Client.Usenet.get_status()     [NEW]   │
│  ├─ List files from save_path               │
│  ├─ Parse/analyze files                     │
│  └─ Create media_file records               │
└─────────────────────────────────────────────┘
          ↓
┌─────────────────────────────────────────────┐
│  Library                                    │
│  ├─ Media items                             │
│  └─ Media files                             │
└─────────────────────────────────────────────┘
```

---

## No Changes Required

These components work with Usenet automatically:

✓ Indexer adapters (Prowlarr, Jackett) - already return NZB URLs
✓ Search jobs (MovieSearch, TVShowSearch) - agnostic to protocol
✓ Release ranking - works with any download_url
✓ MediaImport job - queries status via generic Client interface
✓ Download monitoring - polls via generic Client interface
✓ Configuration UI - already handles multiple client types
✓ Event tracking - already protocol-agnostic
✓ Library management - file-based, protocol-independent

---

## Quick Start Checklist

- [ ] Create `lib/mydia/downloads/client/usenet.ex`
- [ ] Implement 7 callbacks from `@behaviour Mydia.Downloads.Client`
- [ ] Test state mapping matches Usenet client API
- [ ] Ensure save_path points to directory with downloaded files
- [ ] Add `:usenet` to config type enum
- [ ] Register in `Downloads.register_clients/0`
- [ ] Write unit tests
- [ ] Test with real SABnzbd/NZBGet instance
- [ ] Test end-to-end: search → download → import

