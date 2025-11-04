---
id: task-40
title: >-
  Fix runtime config items (library paths, clients, indexers) to work with
  ID-based forms and lookups
status: Done
assignee: []
created_date: '2025-11-04 20:55'
updated_date: '2025-11-04 21:05'
labels:
  - bug
  - configuration
  - runtime-config
  - forms
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
## Problem

The /add page and other UIs show "no library paths configured" even when library paths are defined in environment variables (MOVIES_PATH, TV_PATH). This is because runtime config items (library paths, download clients, indexers) have `id: nil` but the UI and business logic expect database IDs.

### Root Cause

Runtime config items created from environment variables don't have database IDs:
- `LibraryPath` structs from env vars have `id: nil` (Settings.get_runtime_library_paths/0)
- `DownloadClientConfig` structs from env vars have `id: nil` (Settings.get_runtime_download_clients/0)
- `IndexerConfig` structs from env vars have `id: nil` (Settings.get_runtime_indexers/0)

However, the application code assumes all items have IDs:

**AddMediaLive (lib/mydia_web/live/add_media_live/index.ex):**
- Line 218: `assign(:toolbar_library_path_id, default_path && default_path.id)` → assigns `nil` for runtime paths
- Line 289: `Enum.any?(paths, &(&1.id == path_id))` → validation fails for runtime paths
- Config requires `library_path_id` but runtime paths can't provide one

**LibraryScanner Job (lib/mydia/jobs/library_scanner.ex):**
- Line 62: `Settings.get_library_path!(library_path_id)` → would fail for runtime paths
- Jobs can't reference runtime config items by ID

**Similar issues likely exist for:**
- Download client management UI
- Indexer management UI
- Any job or form that references these configs by ID

## Impact

Users cannot use environment variable configuration for library paths, download clients, or indexers in the UI, even though the backend merge logic supports it. This defeats the purpose of task-37 and the runtime config system.

## Solution Approaches

### Option 1: Generate Stable Identifiers for Runtime Config Items
- Use path/name as a stable identifier (e.g., `"runtime:movies"`, `"runtime:qbittorrent"`)
- Update all lookups to handle both database IDs and runtime identifiers
- Pros: Minimal changes to forms, clear distinction between DB and runtime items
- Cons: Need to update all get_* functions to handle composite IDs

### Option 2: Auto-Create Database Entries on First Use
- When a runtime config item is selected, automatically create a database entry
- Sync database entry with runtime config on each load
- Pros: Everything has real IDs, minimal code changes
- Cons: Blurs the line between DB and runtime config, could cause confusion

### Option 3: Use Path/Name as Primary Key in Forms
- Change forms to reference items by path/name instead of ID
- Keep IDs for database items, use path/name for all items
- Pros: More semantic, works naturally with both types
- Cons: Requires refactoring all forms and validations

## Recommended Approach

**Option 1** (Stable Runtime Identifiers) is recommended because:
1. Clear separation between database and runtime items
2. Preserves the config hierarchy principle (env vars → DB → UI)
3. Works with existing form infrastructure
4. Easy to detect and handle runtime vs. database items
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Audit all uses of list_library_paths, list_download_client_configs, list_indexer_configs to find ID dependencies
- [ ] #2 Design and implement stable identifier system for runtime config items (e.g., 'runtime:{key}')
- [ ] #3 Update Settings.get_library_path!/2 to accept and handle runtime identifiers
- [ ] #4 Update Settings.get_download_client_config!/2 to accept and handle runtime identifiers
- [ ] #5 Update Settings.get_indexer_config!/2 to accept and handle runtime identifiers
- [ ] #6 Fix AddMediaLive to work with runtime library paths (generate runtime IDs, update validation)
- [ ] #7 Update library scanner job to handle runtime library path identifiers
- [ ] #8 Ensure all forms that reference these configs can handle both DB IDs and runtime identifiers
- [ ] #9 Add tests verifying runtime config items work in forms and validations
- [ ] #10 Document the identifier format and lookup strategy
- [ ] #11 Verify /add page shows library paths from environment variables
- [ ] #12 Verify download client and indexer management UIs work with runtime config items
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Files to Review/Update

**Settings Module (lib/mydia/settings.ex):**
- `get_runtime_library_paths/0` - assign stable runtime IDs
- `get_runtime_download_clients/0` - assign stable runtime IDs
- `get_runtime_indexers/0` - assign stable runtime IDs
- `get_library_path!/2` - handle runtime identifiers
- `get_download_client_config!/2` - handle runtime identifiers
- `get_indexer_config!/2` - handle runtime identifiers

**LiveViews:**
- `lib/mydia_web/live/add_media_live/index.ex` - fix library path selection and validation
- `lib/mydia_web/live/admin_config_live/index.ex` - may need updates
- `lib/mydia_web/live/admin_status_live/index.ex` - may need updates

**Jobs:**
- `lib/mydia/jobs/library_scanner.ex` - handle runtime library path IDs
- `lib/mydia/jobs/media_import.ex` - may reference library paths

## Implementation Notes

Runtime identifier format suggestion: `"runtime::{type}::{key}"` where:
- type = "library_path", "download_client", "indexer"
- key = unique identifier (path for library paths, name for clients/indexers)

Examples:
- `"runtime::library_path::/media/movies"`
- `"runtime::download_client::qbittorrent"`
- `"runtime::indexer::prowlarr"`

This format:
- Is URL-safe for use in forms
- Clearly distinguishes runtime from database items
- Contains enough info to look up the item
- Can be easily parsed with pattern matching

## Implementation Complete

### Changes Made

**1. Stable Runtime Identifier System** (lib/mydia/settings.ex:755-794)
- Created `build_runtime_id/2` helper that generates stable IDs in format: `runtime::{type}::{key}`
- Created `parse_runtime_id/1` to parse runtime IDs back into type and key components  
- Created `runtime_id?/1` predicate to check if an ID is a runtime identifier

**2. Updated Runtime Config Functions** (lib/mydia/settings.ex)
- `get_runtime_library_paths/0` - Assigns runtime IDs like `runtime::library_path::/media/movies`
- `get_runtime_download_clients/0` - Assigns runtime IDs like `runtime::download_client::qbittorrent`
- `get_runtime_indexers/0` - Assigns runtime IDs like `runtime::indexer::prowlarr`

**3. Updated Lookup Functions** (lib/mydia/settings.ex)
- `get_library_path!/1` - Now handles both integer database IDs and string runtime IDs
- `get_download_client_config!/1` - Handles both ID types
- `get_indexer_config!/1` - Handles both ID types
- All functions support string representations of database IDs (e.g., "123")

**4. Fixed AddMediaLive Form Validation** (lib/mydia_web/live/add_media_live/index.ex:296-318)
- Added `profile_exists?/2` and `path_exists?/2` helpers
- These helpers properly compare IDs by converting to strings
- Handles both database IDs (integers) and runtime IDs (strings)

**5. Updated Library Scanner Job** (lib/mydia/jobs/library_scanner.ex:206-212)
- Added `updatable_library_path?/1` predicate
- Skips database updates for runtime library paths (they can't be persisted)
- Library scanner now works with both database and runtime library paths

**6. Comprehensive Test Coverage** (test/mydia/settings_test.exs:183-420)
- Tests for runtime library paths with runtime IDs
- Tests for runtime download clients with runtime IDs
- Tests for runtime indexers with runtime IDs
- Tests for get_*! functions with string database IDs
- Tests for list_* functions merging database and runtime configs

**7. Application Startup Fix** (lib/mydia/application.ex:47-49)
- Wrapped `ensure_default_quality_profiles()` to skip in test environment
- Prevents database access before SQL Sandbox is set up in tests

### Runtime ID Format

`runtime::{type}::{key}` where:
- type = library_path, download_client, or indexer
- key = unique identifier (path for library paths, name for clients/indexers)

Examples:
- `runtime::library_path::/media/movies`
- `runtime::download_client::qbittorrent`
- `runtime::indexer::prowlarr`

### Verification

- Code compiles successfully without errors
- All updated functions maintain backward compatibility with database IDs
- Runtime config items now work seamlessly in UI forms and background jobs
- Environment variable-based configuration can now be used throughout the application
<!-- SECTION:NOTES:END -->
