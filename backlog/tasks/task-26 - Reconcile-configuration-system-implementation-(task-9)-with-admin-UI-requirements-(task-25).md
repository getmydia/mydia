---
id: task-26
title: >-
  Reconcile configuration system implementation (task 9) with admin UI
  requirements (task 25)
status: Done
assignee:
  - assistant
created_date: '2025-11-04 04:06'
updated_date: '2025-11-04 04:27'
labels:
  - configuration
  - refactoring
  - admin
  - technical-debt
dependencies:
  - task-9
  - task-25
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Task 9 implemented a configuration system with precedence: env vars > YAML > defaults. However, task 25 requires a different precedence that includes database/UI overrides: env vars > database/UI > config.yml > defaults.

The current implementation needs to be reviewed and potentially refactored to support the database/UI configuration layer, which should:
1. Allow UI-based configuration changes to override YAML config
2. Prevent UI changes from overriding environment variables
3. Store UI changes in the database (likely using the existing ConfigSetting schema)
4. Display configuration source clearly (env var, database/UI, YAML, or default)

This task involves:
- Reviewing the current implementation in lib/mydia/config/loader.ex
- Understanding how the existing ConfigSetting database schema fits into the precedence chain
- Modifying the loader to incorporate database settings in the correct precedence order
- Ensuring the Settings context provides both read and write operations for UI-managed config
- Updating tests to verify the 4-layer precedence works correctly
- Documenting the configuration architecture for future maintainers
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Configuration precedence correctly implements: env vars > database/UI > config.yml > defaults
- [x] #2 Loader.load/1 incorporates database settings from ConfigSetting schema
- [x] #3 Settings context provides functions to read and write UI-managed config
- [x] #4 UI-managed config changes are persisted to database
- [x] #5 Environment variables cannot be overridden by database/UI settings
- [x] #6 All existing tests pass plus new tests for database layer precedence
- [x] #7 Documentation updated to explain 4-layer configuration architecture
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
## Implementation Plan

### Overview
Modify the configuration loader to support 4-layer precedence:
**env vars > database/UI > YAML > defaults**

### Changes

1. **Add database config loader to Settings context**
   - Create `Settings.load_database_config/0`
   - Convert flat ConfigSetting records to nested maps
   - Parse values by type (integers, booleans, strings)

2. **Modify Config.Loader**
   - Add `load_database/1` private function
   - Update merge order: defaults → YAML → database → env vars
   - Handle database unavailability gracefully
   - Accept optional `:repo` parameter for dependency injection

3. **Add comprehensive tests**
   - Test database settings override YAML
   - Test env vars override database settings
   - Test complete 4-layer precedence chain
   - Test behavior when database is unavailable

4. **Update documentation**
   - Update Config.Loader moduledoc
   - Update Settings context docs
   - Update ConfigSetting schema docs

### Key Design Decisions
- ConfigSetting keys use dot notation (e.g., "server.port")
- Type inference from Schema or explicit casting
- Graceful fallback when database unavailable
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implementation completed successfully. All 25 tests passing, including 8 new tests for 4-layer precedence validation.

Fixed test database schema issue by recreating test database with proper migrations.

All acceptance criteria met: env vars > database/UI > YAML > defaults precedence is working correctly.
<!-- SECTION:NOTES:END -->
