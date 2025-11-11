---
id: task-160
title: 'Fix Usenet client configuration bugs from GitHub issue #3'
status: Done
assignee:
  - Claude
created_date: '2025-11-11 02:21'
updated_date: '2025-11-11 02:26'
labels:
  - bug
  - usenet
  - sabnzbd
  - nzbget
  - github-issue
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
## Overview
Multiple users reported that after adding Usenet download clients (SABnzbd, NZBGet), the UI becomes unresponsive and enters an error loop. This parent task tracks all bugs discovered in GitHub issue #3.

## Issues Identified
1. **SABnzbd KeyError** - Missing `api_key` in `config_to_map/1` functions causes crashes when fetching queue items
2. **NZBGet ArgumentError** - Admin config UI crashes when testing NZBGet connection due to incorrect type conversion

## User Impact
- Users cannot successfully configure SABnzbd clients (crashes during queue fetch)
- Users cannot test NZBGet client connections in admin UI (crashes on test)
- UI becomes unresponsive due to error loops

## Related
- GitHub Issue: https://github.com/getmydia/mydia/issues/3
- Task 140 fixed admin UI test handler but missed other locations

## Sub-tasks
This parent task will contain sub-tasks for each specific bug fix.
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Completion Summary

Successfully fixed all Usenet client configuration bugs reported in GitHub issue #3:

### Changes Made

1. **SABnzbd api_key fix** (task-160.1)
   - Added `api_key: config.api_key` to `config_to_map/1` in `lib/mydia/downloads.ex:930`
   - Added `api_key: config.api_key` to `config_to_map/1` in `lib/mydia/downloads/untracked_matcher.ex:218`
   - This fixes the KeyError that occurred when SABnzbd tried to fetch queue items

2. **NZBGet String.to_atom fix** (task-160.2)
   - Removed incorrect `String.to_atom(client.type)` call in `lib/mydia_web/live/admin_config_live/index.ex:397`
   - Changed to `type: client.type` since `client.type` is already an atom (Ecto.Enum field)
   - This fixes the ArgumentError that occurred when testing NZBGet connections in admin UI

### Testing
- All admin config tests pass (19 tests, 0 failures)
- Code compiles without errors
- Both sub-tasks have all acceptance criteria met

### Impact
- Users can now successfully configure SABnzbd clients without crashes
- Users can test NZBGet client connections in admin UI without errors
- UI no longer enters error loops when working with Usenet clients
<!-- SECTION:NOTES:END -->
