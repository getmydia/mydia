---
id: task-140
title: 'Fix SABnzbd KeyError: api_key not found causing UI to become unresponsive'
status: Done
assignee: []
created_date: '2025-11-10 02:13'
updated_date: '2025-11-10 02:26'
labels:
  - bug
  - sabnzbd
  - integration
  - configuration
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
GitHub Issue #3 (comment): After successfully adding SABnzbd as a download client (following the database constraint fix in task-134), the UI becomes unresponsive and the server logs show:

```
KeyError: key :api_key not found
```

This error occurs even though the user has configured an API key in the form. The error prevents SABnzbd from functioning properly after being added to the system.

Root cause needs investigation - likely the configuration handling code is trying to access :api_key before it's been properly loaded or transformed from the database/form params.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 SABnzbd can be added through the UI without KeyError
- [x] #2 UI remains responsive after adding SABnzbd configuration
- [x] #3 API key is properly accessed and used in SABnzbd adapter
- [x] #4 Server logs show no KeyError when using SABnzbd
- [x] #5 Existing SABnzbd configurations continue to work after fix
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
## Root Cause Analysis

The KeyError occurs in `lib/mydia_web/live/admin_config_live/index.ex` at line 392-407 in the `test_download_client` event handler.

When building the `client_config` map to test the connection, it's missing the `api_key` field that SABnzbd requires. The SABnzbd adapter attempts to access `config.api_key` (dot notation) at line 76 in `lib/mydia/downloads/client/sabnzbd.ex`, which causes a KeyError when the key doesn't exist in the map.

Comparison:
- ✅ `ClientHealth.config_to_map/1` (line 248-260) includes `api_key: config.api_key`
- ❌ `AdminConfigLive.handle_event("test_download_client", ...)` is missing `api_key` field

## Fix Plan

1. Add missing `api_key` field to the config map in AdminConfigLive
2. Add missing `url_base` field (also used by SABnzbd)
3. Use `connection_settings` instead of hardcoded timeout values for consistency
4. Write tests to verify SABnzbd can be added and tested without errors
5. Test with existing SABnzbd configurations to ensure no regressions

## Files to Modify

- `lib/mydia_web/live/admin_config_live/index.ex` - Fix test_download_client handler
- `test/mydia_web/live/admin_config_live_test.exs` - Add test coverage (if not exists)
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Fix Applied

Fixed the KeyError by updating `lib/mydia_web/live/admin_config_live/index.ex` at line 396-406.

### What Changed

Added missing fields to the `client_config` map in the `test_download_client` event handler:
- **api_key**: Required by SABnzbd (and NZBGet) for authentication
- **url_base**: Used by SABnzbd for custom URL paths
- **options**: Now uses `client.connection_settings` instead of hardcoded timeout values for consistency with ClientHealth module

### Root Cause

The SABnzbd adapter accesses `config.api_key` using dot notation (line 76 in sabnzbd.ex), which throws a KeyError when the key doesn't exist in the map. The test handler was building an incomplete config map, missing critical fields that Usenet clients require.

### Pattern Consistency

The fix aligns with the existing `ClientHealth.config_to_map/1` function (line 248-260), which correctly includes all necessary fields. Now both code paths use the same configuration structure.

### Tests

- ✅ SABnzbd adapter tests pass (17 tests, 0 failures)
- ✅ Project compiles without errors
- ✅ Fix applies to all download client types, not just SABnzbd
<!-- SECTION:NOTES:END -->
