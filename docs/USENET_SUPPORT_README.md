# Usenet Support Architecture Documentation

This directory contains comprehensive documentation for implementing Usenet support in Mydia.

## Files in This Documentation

### 1. **USENET_ARCHITECTURE_ANALYSIS.md** (Start Here!)
   **Purpose:** Complete architectural overview and deep-dive
   
   **Contents:**
   - Executive summary of download infrastructure
   - Detailed explanation of each component (client system, monitoring, import, indexers)
   - Current download protocols and how they work
   - Adapter behavior pattern explained
   - Configuration system
   - Search job architecture (movies and TV)
   - Metadata management and file analysis
   - Complete data flow examples
   - Integration points for Usenet support
   - Design patterns in use
   - Performance considerations
   - Known limitations
   
   **Best for:** Understanding the full architecture, design decisions, and integration philosophy

### 2. **USENET_QUICK_REFERENCE.md** (Use During Implementation)
   **Purpose:** Tactical implementation guide with specific code examples
   
   **Contents:**
   - File locations and key modules
   - Implementation checklist
   - SABnzbd-specific API examples
   - NZBGet-specific API examples
   - Required status map structure
   - HTTP client utilities reference
   - State transition flow diagram
   - Testing templates (unit and integration)
   - Debugging tips
   - Quick start checklist
   - No changes required checklist
   
   **Best for:** Implementing the Usenet adapter, referring to during development

### 3. **This File (USENET_SUPPORT_README.md)**
   High-level navigation and quick summaries

## Quick Summary

### The Problem
Mydia currently supports torrent downloads (qBittorrent, Transmission) but not Usenet. Adding Usenet support requires understanding how downloads are handled to ensure clean integration.

### The Solution
The application is already architected for this! It uses a **protocol-agnostic adapter pattern** where:
1. Each download client type implements a defined interface (behavior)
2. A registry maps client types to adapter modules
3. All other code (search, monitoring, import) uses the generic interface
4. No protocol-specific logic outside the adapter

### The Implementation
Adding Usenet support requires:

1. **Create `lib/mydia/downloads/client/usenet.ex`** (150-300 lines)
   - Implement `@behaviour Mydia.Downloads.Client`
   - Handle SABnzbd or NZBGet API calls
   - Map states and return standardized status maps

2. **Update `lib/mydia/settings/download_client_config.ex`** (1 line)
   - Add `:usenet` to `@client_types`

3. **Update `lib/mydia/downloads.ex`** (1 line)
   - Register the adapter in `register_clients/0`

4. **No other changes needed!**
   - Search jobs work automatically
   - Download monitoring works automatically
   - Media import works automatically
   - Configuration UI already multi-client aware

## Architecture at a Glance

```
Indexers (Prowlarr/Jackett)
├─ Return search results with download URLs
├─ URLs can be magnet links (torrents) or NZB URLs
└─ No changes needed for Usenet

Downloads.initiate_download()
├─ Selects client (by priority or name)
├─ Loads adapter (Qbittorrent, Transmission, or Usenet)
├─ Calls adapter.add_torrent()
└─ Creates download record

DownloadMonitor Job (polling)
├─ Queries all clients via adapter.list_torrents()
├─ Detects state changes
├─ Enqueues MediaImport for completed downloads

MediaImport Job
├─ Queries client via adapter.get_status()
├─ Gets save_path (where files are)
├─ Organizes files into library
└─ Creates media_file records

Library
└─ Contains organized media files (protocol-independent)
```

## Key Design Patterns

### 1. Adapter Pattern
- Well-defined behavior: `Mydia.Downloads.Client`
- Pluggable implementations
- Registry-based lookup
- No coupling between components

### 2. Stateless Client Status
- Downloads table stores metadata only
- Real-time status from clients on demand
- Single source of truth: the clients themselves

### 3. Ephemeral Download Queue
- Downloads deleted after import
- Library is source of truth for what's been downloaded
- Only active downloads in database

### 4. Protocol Independence
- Search, monitoring, import don't care how files arrive
- Only care about: presence, location, completion status
- Works for torrents, Usenet, HTTP, etc.

## File Structure

```
lib/mydia/
├── downloads/
│   ├── client.ex                    # Behavior definition (335 lines)
│   ├── client/
│   │   ├── qbittorrent.ex          # Reference implementation
│   │   ├── transmission.ex         # Another implementation
│   │   ├── usenet.ex               # NEW - Create this
│   │   ├── http.ex                 # Shared HTTP utilities
│   │   ├── error.ex                # Error types
│   │   └── registry.ex             # Adapter registration
│   ├── download.ex                 # Schema (51 lines)
│   └── downloads.ex                # Context functions (400+ lines)
│
├── settings/
│   └── download_client_config.ex   # Config schema (UPDATE: add :usenet type)
│
├── jobs/
│   ├── download_monitor.ex         # Status polling (198 lines)
│   ├── media_import.ex             # File organization (770 lines)
│   ├── movie_search.ex             # Movie search (276 lines)
│   └── tv_show_search.ex           # TV search (867 lines)
│
└── indexers/
    ├── adapter.ex                  # Behavior definition
    ├── search_result.ex            # Normalized results (209 lines)
    └── adapter/
        ├── prowlarr.ex             # Already returns NZB URLs
        └── jackett.ex              # Already returns NZB URLs
```

## Reading Guide

### For Architects
1. Read USENET_ARCHITECTURE_ANALYSIS.md sections 1-8
2. Review design patterns (section 8)
3. Understand integration philosophy (section 7)

### For Implementers
1. Read USENET_QUICK_REFERENCE.md - all sections
2. Use implementation checklist
3. Refer to code examples for SABnzbd/NZBGet

### For Code Reviewers
1. Check implementation against behavior definition (client.ex)
2. Verify state mapping is correct
3. Ensure status_map structure matches spec
4. Test error handling

## Implementation Effort

| Task | Hours | Complexity |
|------|-------|-----------|
| Create adapter module | 4-8 | Medium |
| Configuration changes | <1 | Trivial |
| Unit tests | 3-6 | Medium |
| Integration tests | 3-6 | Medium |
| **Total** | **10-20** | **Medium** |

## Next Steps

1. Choose Usenet client (SABnzbd recommended for simpler API)
2. Read the architecture analysis thoroughly
3. Study qBittorrent adapter as reference implementation
4. Review SABnzbd/NZBGet API documentation
5. Create usenet.ex following the quick reference checklist
6. Implement unit tests first
7. Test with real client in Docker
8. Test full pipeline: search → download → monitor → import

## Key Files to Study

### Must Read (for complete understanding)
- `lib/mydia/downloads/client.ex` - Behavior definition
- `lib/mydia/downloads/client/qbittorrent.ex` - Reference implementation
- `lib/mydia/jobs/download_monitor.ex` - How monitoring works
- `lib/mydia/jobs/media_import.ex` - How import works

### Should Read (for context)
- `lib/mydia/downloads.ex` - Client selection and download initiation
- `lib/mydia/settings/download_client_config.ex` - Configuration schema
- `lib/mydia/jobs/movie_search.ex` - How search initiates downloads
- `lib/mydia/downloads/client/http.ex` - Shared HTTP utilities

### Reference (for implementation details)
- `lib/mydia/indexers/search_result.ex` - What search returns
- `lib/mydia/downloads/download.ex` - Download database schema
- `lib/mydia/library/metadata_enricher.ex` - Media enrichment

## Common Questions

**Q: Will I need to modify search jobs?**
A: No. They're already protocol-agnostic. Once you register the adapter, searches will automatically work with Usenet.

**Q: Will media import need changes?**
A: No. It queries status via the adapter's get_status() method, which is generic. Works with any protocol.

**Q: What about configuration UI?**
A: Already multi-client aware. Just needs `:usenet` type added to the enum.

**Q: How does the system know which client to use?**
A: `select_download_client()` picks by priority (default) or explicit client name. No adapter awareness needed by callers.

**Q: What if NZB unpacks to a directory with multiple files?**
A: MediaImport already handles this. It lists all files from save_path and filters video files.

**Q: Do I need to implement season pack logic?**
A: No. Search jobs handle that. Your adapter just needs to add the NZB and track its status.

## Documentation Versions

- **Generated:** 2024-11-07
- **For Mydia:** Latest development version
- **Scope:** Download infrastructure, media import, usenet integration

---

**Ready to implement?** Start with USENET_QUICK_REFERENCE.md and follow the checklist!

**Need to understand the architecture first?** Read USENET_ARCHITECTURE_ANALYSIS.md sections 1-8.
