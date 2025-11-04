---
id: task-21.1
title: Create download client adapter abstraction layer
status: Done
assignee: []
created_date: '2025-11-04 03:33'
updated_date: '2025-11-04 03:43'
labels:
  - downloads
  - architecture
  - backend
dependencies: []
parent_task_id: task-21
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Design and implement the core abstraction layer for download client integrations. This includes creating an Elixir behaviour that defines the common interface all download client adapters must implement, along with shared utilities for connection management, error handling, and response parsing.

The abstraction should support the operations needed across all download clients: adding torrents (file or magnet link), checking status, removing torrents, and retrieving download progress. Follow Phoenix/Ecto patterns for adapter design.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Behaviour module defines callbacks for add_torrent, get_status, list_torrents, remove_torrent, and test_connection
- [x] #2 Common error types are defined and handled consistently
- [x] #3 Adapter registry system allows runtime selection of configured clients
- [x] #4 Shared HTTP client configuration using Req library
- [x] #5 Documentation includes examples of implementing a new adapter
- [x] #6 Unit tests verify behaviour contract
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Implementation Complete

Successfully implemented the download client adapter abstraction layer with all required components:

### Files Created

1. **Behaviour Module** (`lib/mydia/downloads/client.ex`)
   - Defines the `@behaviour` with 7 callbacks: test_connection, add_torrent, get_status, list_torrents, remove_torrent, pause_torrent, resume_torrent
   - Comprehensive documentation with examples and type specs
   - Defines standard types: config, torrent_input, torrent_state, status_map, and options types

2. **Error Module** (`lib/mydia/downloads/client/error.ex`)
   - Defines 12 error types: connection_failed, authentication_failed, timeout, not_found, invalid_torrent, duplicate_torrent, insufficient_space, invalid_config, api_error, network_error, parse_error, unknown
   - Helper functions for creating each error type
   - `from_req_error/1` function to convert Req errors to download client errors
   - Implements Exception protocol for proper error raising

3. **Registry Module** (`lib/mydia/downloads/client/registry.ex`)
   - Agent-based registry for runtime adapter selection
   - Functions: register/2, get_adapter/1, get_adapter!/1, list_adapters/0, registered?/1, unregister/1, clear/0
   - Integrated into application supervision tree in `lib/mydia/application.ex`

4. **HTTP Client Module** (`lib/mydia/downloads/client/http.ex`)
   - Shared HTTP utilities using Req library
   - Functions: new_request/1, get/3, post/3, put/3, delete/3, request/2, form_body/1
   - Automatic authentication handling (Basic auth)
   - Configurable timeouts and connection options
   - Automatic error conversion to download client errors

5. **Documentation** (`lib/mydia/downloads/client/ADAPTER_GUIDE.md`)
   - Comprehensive guide for implementing new adapters
   - Step-by-step instructions with code examples
   - Best practices and common patterns
   - Reference to future qBittorrent implementation

### Tests Created

1. **Error Tests** (`test/mydia/downloads/client/error_test.exs`) - 28 tests
   - Tests all error creation functions
   - Tests Req error conversion
   - Tests error message formatting
   - Tests Exception protocol implementation

2. **Registry Tests** (`test/mydia/downloads/client/registry_test.exs`) - 18 tests
   - Tests registration and retrieval
   - Tests error handling for unknown adapters
   - Tests clearing and listing
   - Tests integration with real adapters

3. **HTTP Tests** (`test/mydia/downloads/client/http_test.exs`) - 12 tests
   - Tests request creation with various configs
   - Tests authentication header setup
   - Tests timeout configuration
   - Tests form body encoding

### Verification

- All 103 tests pass (58 new tests for download client abstraction)
- Code compiles without warnings
- Code formatted with `mix format`
- Registry integrated into application supervision tree
- Ready for adapter implementations (qBittorrent, Transmission)

### Architecture Notes

The abstraction layer follows Phoenix/Ecto adapter patterns:

1. **Behaviour-based design**: Clear contract for all adapters
2. **Consistent error handling**: All errors use the Error struct
3. **Runtime adapter selection**: Registry allows dynamic client selection
4. **Shared HTTP utilities**: Reduces code duplication across adapters
5. **Comprehensive documentation**: Easy for developers to implement new adapters

The implementation is complete and ready for concrete adapter implementations in tasks 21.2 (qBittorrent), 21.3 (Transmission), etc.
<!-- SECTION:NOTES:END -->
