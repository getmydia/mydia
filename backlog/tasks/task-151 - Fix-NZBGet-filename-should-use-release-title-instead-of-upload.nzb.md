---
id: task-151
title: Fix NZBGet filename - should use release title instead of "upload.nzb"
status: Done
assignee: []
created_date: '2025-11-10 18:51'
updated_date: '2025-11-10 19:01'
labels:
  - enhancement
  - nzbget
  - usenet
  - ux
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
## Problem

When downloading NZB files to NZBGet, the client shows the download as "upload.nzb" instead of the actual release title. This makes it hard to identify downloads in the NZBGet UI.

## Current Behavior

NZBGet logs show:
```
[INFO] Adding collection upload.nzb to queue
[INFO] Collection upload added to queue
[INFO] Reordering files for upload
```

The download appears in NZBGet as "upload" rather than "Predator.Badlands.2025.REPACK.1080p.TELESYNC.x264-SyncUP".

## Expected Behavior

NZBGet should show:
```
[INFO] Adding collection Predator.Badlands.2025.REPACK.1080p.TELESYNC.x264-SyncUP.nzb to queue
```

And the download should appear with the proper release name in the NZBGet UI.

## Root Cause

The NZBGet client adapter (`lib/mydia/downloads/client/nzbget.ex`) likely passes the NZB file content without specifying a proper filename. The NZBGet API supports passing a filename parameter that controls what name is displayed.

## Investigation Needed

1. Check how we're calling the NZBGet API in `lib/mydia/downloads/client/nzbget.ex`
2. Verify if we're passing a filename parameter
3. If not, update the API call to include the release title as the filename (e.g., `"#{search_result.title}.nzb"`)

## Files to Check

- `lib/mydia/downloads/client/nzbget.ex` - NZBGet adapter implementation
- NZBGet API documentation for the append/upload endpoint

## Acceptance Criteria

- NZB downloads show the correct release title in NZBGet instead of "upload.nzb"
- The title matches the original SearchResult title
- Downloads are easily identifiable in the NZBGet queue
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Investigation Complete

### Root Cause Identified

Line 141 in `lib/mydia/downloads/client/nzbget.ex` hardcodes the filename to "upload.nzb":

```elixir
nzb_filename = "upload.nzb"
```

This is the NZBFilename parameter passed to NZBGet's `append` API method.

### Solution

1. Accept an optional `:filename` or `:title` parameter in the opts for the `add_torrent/3` function
2. Use the provided title to construct the filename (e.g., `"#{title}.nzb"`)
3. Update `Downloads.initiate_download/2` to pass the search_result.title through the call chain

### Files to Modify

- `lib/mydia/downloads/client/nzbget.ex` - Accept title in opts and use it for filename
- `lib/mydia/downloads.ex` - Pass search_result.title in opts when calling add_torrent

## Implementation Complete

### Changes Made

1. **lib/mydia/downloads/client/nzbget.ex:139-146** - Modified `do_add_nzb/3` to accept a `:title` option and use it for the filename instead of hardcoding "upload.nzb"
2. **lib/mydia/downloads.ex:383-387** - Updated `select_and_add_to_client/2` to add the search_result.title to opts
3. **lib/mydia/downloads.ex:413-431** - Modified `add_torrent_to_client_with_input/4` to pass the title through to the client

### Test Results

All download tests pass (34 tests, 0 failures):
- lib/mydia/downloads_test.exs: ✓

The fix correctly passes the release title to NZBGet, which will now display downloads with their proper names instead of "upload.nzb".
<!-- SECTION:NOTES:END -->
