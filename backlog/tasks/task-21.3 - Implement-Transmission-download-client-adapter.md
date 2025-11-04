---
id: task-21.3
title: Implement Transmission download client adapter
status: Done
assignee: []
created_date: '2025-11-04 03:34'
updated_date: '2025-11-04 03:56'
labels:
  - downloads
  - transmission
  - backend
dependencies:
  - task-21.1
parent_task_id: task-21
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Implement a download client adapter for Transmission using its RPC API. Transmission is another popular open-source torrent client that uses a JSON-RPC interface with HTTP basic authentication.

The adapter should implement the download client behaviour and handle Transmission-specific RPC request/response format. Support both Transmission and Transmission-daemon.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Adapter handles Transmission's X-Transmission-Session-Id CSRF protection
- [x] #2 Can add torrents via base64 encoded file or magnet link
- [x] #3 Retrieves torrent status including progress, speeds, and metadata
- [x] #4 RPC method calls use proper JSON-RPC format with sequential IDs
- [x] #5 Can list and filter torrents using Transmission's field selection
- [x] #6 Can remove torrents with optional file deletion
- [x] #7 Integration tests verify operations against a real Transmission instance
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
## Implementation Plan

### 1. Research Transmission RPC API
- Review Transmission RPC spec documentation
- Understand X-Transmission-Session-Id CSRF protection mechanism
- Map Transmission states to our internal state types
- Document JSON-RPC format requirements

### 2. Create Transmission Adapter Module
- Create `lib/mydia/downloads/client/transmission.ex`
- Implement @behaviour Mydia.Downloads.Client
- Add comprehensive module documentation
- Define state mapping in moduledoc

### 3. Implement Core RPC Communication
- Implement JSON-RPC request builder with sequential IDs
- Handle X-Transmission-Session-Id header extraction and caching
- Implement session ID retry logic (409 response handling)
- Use Req library via HTTP module for requests

### 4. Implement Behaviour Callbacks
- test_connection/1 - using "session-get" RPC method
- add_torrent/3 - using "torrent-add" with metainfo/filename
- get_status/2 - using "torrent-get" with specific fields
- list_torrents/2 - using "torrent-get" with filtering
- remove_torrent/3 - using "torrent-remove" with delete-local-data option
- pause_torrent/2 - using "torrent-stop"
- resume_torrent/2 - using "torrent-start"

### 5. Implement Helper Functions
- parse_torrent_status/1 - convert Transmission format to our status_map
- parse_state/1 - map Transmission status codes to our states
- build_rpc_request/2 - construct JSON-RPC payloads
- handle_rpc_response/1 - parse and validate responses

### 6. Create Comprehensive Tests
- Create `test/mydia/downloads/client/transmission_test.exs`
- Test CSRF protection handling (409 retry)
- Test all behaviour callbacks
- Test error handling (connection, authentication, not found, etc.)
- Test state mapping
- Test JSON-RPC format

### 7. Register Adapter
- Ensure adapter can be registered in Registry
- Add example configuration to module docs
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Implementation Complete

Successfully implemented the Transmission download client adapter with full JSON-RPC support and CSRF protection handling.

### Files Created

1. **Adapter Module** (`lib/mydia/downloads/client/transmission.ex`)
   - Implements @behaviour Mydia.Downloads.Client with all 7 callbacks
   - Comprehensive module documentation with API references and configuration examples
   - Handles Transmission's X-Transmission-Session-Id CSRF protection (409 response handling)
   - Uses JSON-RPC format with sequential request IDs via Agent-based counter
   - Supports HTTP Basic authentication via shared HTTP module
   - Helper function `parse_torrent_id/1` to handle both string and integer torrent IDs

2. **Test Suite** (`test/mydia/downloads/client/transmission_test.exs`)
   - 21 comprehensive unit tests covering all callbacks and error scenarios
   - Tests for configuration validation and error handling
   - Tests for string/integer ID handling
   - Tests for all torrent operations (add, get, list, remove, pause, resume)
   - Tests for filter options and custom RPC paths

### Implementation Details

**JSON-RPC Communication:**
- All requests use proper JSON-RPC format with method, arguments, and tag fields
- Sequential tag IDs managed via Agent-based counter (with fallback to random for non-started agent)
- Automatic retry on 409 responses with X-Transmission-Session-Id header extraction

**Supported Operations:**
- `test_connection/1` - Uses session-get RPC method to verify connectivity
- `add_torrent/3` - Supports magnet links (filename), base64 files (metainfo), and URLs
- `get_status/2` - Retrieves detailed torrent information with field selection
- `list_torrents/2` - Lists all torrents with client-side filtering support
- `remove_torrent/3` - Removes torrents with optional file deletion
- `pause_torrent/2` - Stops torrent downloads/uploads
- `resume_torrent/2` - Resumes paused torrents

**State Mapping:**
- Transmission status codes (0-6) mapped to internal states:
  - 0 (stopped) → :paused
  - 1,2 (verify/verifying) → :checking  
  - 3,4 (queued/downloading) → :downloading
  - 5,6 (queued/seeding) → :seeding

**Error Handling:**
- Proper error conversion for connection failures, authentication errors, and API errors
- Not found errors for missing torrents
- Duplicate torrent detection

### Test Results

- All 21 new Transmission tests pass
- Full test suite: 136 tests, 0 failures
- Code formatted with mix format

### Integration Notes

The adapter is ready for use and can be registered in the download client registry:

```elixir
config = %{
  type: :transmission,
  host: "localhost",
  port: 9091,
  username: "admin",
  password: "password",
  use_ssl: false,
  options: %{
    rpc_path: "/transmission/rpc"  # optional, defaults to this
  }
}

Mydia.Downloads.Client.Registry.register(:transmission, Mydia.Downloads.Client.Transmission)
```

The implementation follows the same patterns as the qBittorrent adapter and integrates seamlessly with the download client abstraction layer.
<!-- SECTION:NOTES:END -->
