---
id: task-37
title: Make library paths work from environment variables without database entries
status: Done
assignee: []
created_date: '2025-11-04 20:37'
updated_date: '2025-11-04 20:38'
labels:
  - bug
  - configuration
  - library
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The Settings.list_library_paths function currently only queries the database, which means library paths from environment variables (MOVIES_PATH, TV_PATH) don't work unless manually added to the database. This violates the design principle that database settings should only override environment variables, not be required.

Fix Settings.list_library_paths to merge both database library paths AND runtime config library paths (from env vars), similar to how list_download_client_configs and list_indexer_configs work.

This ensures users can configure library paths via environment variables in compose.override.yml without needing to manually create database entries.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Settings.list_library_paths returns library paths from both database and runtime config
- [x] #2 Library paths from MOVIES_PATH and TV_PATH environment variables are automatically available
- [x] #3 Database library paths take precedence over environment variable paths (by path)
- [x] #4 Users can see and use library paths configured via environment variables without database entries
- [x] #5 The merge logic follows the same pattern as download clients and indexers
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Implementation Complete

Updated `Settings.list_library_paths/1` to merge both database and runtime config library paths, following the same pattern as download clients and indexers.

**Changes made:**
1. Modified `Settings.list_library_paths/1` to query both database and runtime config
2. Added `Settings.get_runtime_library_paths/0` to convert MOVIES_PATH and TV_PATH environment variables to LibraryPath structs
3. Database paths take precedence over environment variable paths (by path)
4. Runtime library paths are created with sensible defaults (monitored: true, scan_interval: 360)

**How it works:**
- When MOVIES_PATH=/media/movies is set, a LibraryPath struct is automatically created for the movies library
- When TV_PATH=/media/tv is set, a LibraryPath struct is automatically created for the TV library
- These paths appear in the UI and function exactly like database-backed paths
- Users can configure library paths purely via environment variables without database entries

The implementation ensures environment variable configuration works out of the box, consistent with the principle that database settings override but don't require environment variables.
<!-- SECTION:NOTES:END -->
