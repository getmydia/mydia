---
id: task-38
title: >-
  Centralize database + runtime config merging logic to eliminate code
  duplication
status: Done
assignee:
  - Claude
created_date: '2025-11-04 20:46'
updated_date: '2025-11-04 20:50'
labels:
  - refactoring
  - configuration
  - code-quality
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Currently, three Settings functions manually implement the same merge logic to combine database records with runtime config from environment variables:
- list_download_client_configs/1
- list_indexer_configs/1  
- list_library_paths/1

This creates ~30 lines of duplicated code and makes the codebase harder to maintain. Each function has to manually:
1. Query database records
2. Get runtime config items
3. Create a MapSet of database keys (by name or path)
4. Filter runtime items to exclude those already in database
5. Concatenate the lists

Refactor this to use a centralized helper function that implements the merge pattern once. This will:
- Eliminate code duplication (DRY principle)
- Make the merge strategy consistent across all config types
- Provide a clear pattern for future collection-based configs
- Make it easier to fix bugs or enhance the merge logic (single location)
- Improve code readability and maintainability

Note: list_config_settings() intentionally remains database-only as it's used by the config loader to build the hierarchy. This task focuses on collection-based configs only.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Create defp merge_with_runtime_config/4 helper function in Settings module
- [x] #2 Helper accepts: db_records, runtime_getter function, merge_key atom, opts
- [x] #3 Helper implements the merge logic: DB records + filtered runtime records (by merge_key)
- [x] #4 Refactor list_download_client_configs/1 to use the helper (merge by :name)
- [x] #5 Refactor list_indexer_configs/1 to use the helper (merge by :name)
- [x] #6 Refactor list_library_paths/1 to use the helper (merge by :path)
- [x] #7 Remove duplicated merge logic from all three functions
- [x] #8 Add module docstring documenting the merge pattern and when to use it
- [x] #9 Add inline documentation explaining that list_config_settings is intentionally database-only
- [x] #10 All existing tests pass without modification
- [x] #11 Code is cleaner with ~30 fewer lines of duplication
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
## Implementation Plan

### Analysis
The three functions (`list_download_client_configs/1`, `list_indexer_configs/1`, `list_library_paths/1`) share identical merge logic but differ in:
- Database schema and query ordering (stays in each function)
- Runtime getter function (will be passed as parameter)
- Merge key field (`:name` for clients/indexers, `:path` for library paths)

### Approach

1. Create centralized helper function `merge_with_runtime_config/4` near other private helpers (~line 670)
   - Parameters: db_records, runtime_getter function, merge_key atom, opts
   - Logic: Get runtime items, create MapSet of DB keys, filter runtime items, concatenate

2. Refactor three list functions to use the helper:
   - `list_download_client_configs/1` - use helper with `&get_runtime_download_clients/0, :name`
   - `list_indexer_configs/1` - use helper with `&get_runtime_indexers/0, :name`
   - `list_library_paths/1` - use helper with `&get_runtime_library_paths/0, :path`

3. Add documentation:
   - Module docstring update explaining merge pattern for collection-based configs
   - Inline comment for `list_config_settings/0` noting it's intentionally database-only

### Expected Changes
- Add: ~15 lines (helper + docs)
- Remove: ~30 lines (duplicated logic)
- Net: ~15 lines fewer, cleaner code

### Testing
All existing tests should pass without modification (behavior unchanged, only implementation refactored)
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Refactoring complete! Successfully consolidated duplicate merge logic into a single helper function.

**Changes made:**
- Created `merge_with_runtime_config/4` private helper function
- Refactored all three list functions to use the helper
- Updated module docstring with merge pattern documentation
- Added inline comment to `list_config_settings/0`

**Result:**
- Removed ~30 lines of duplicated code
- No compilation warnings
- Consistent merge behavior across all config types
- Clear pattern for future collection-based configs
<!-- SECTION:NOTES:END -->
