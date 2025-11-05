---
id: task-82
title: Fix background download monitor creating duplicate downloads
status: Done
assignee: []
created_date: '2025-11-05 18:43'
updated_date: '2025-11-05 18:51'
labels:
  - bug
  - downloads
  - background-monitor
  - deduplication
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The background download monitor is not properly detecting existing downloaded files and is creating duplicate downloads.

**Observed Issue:**
- Big Buck Bunny already had a file downloaded
- System added a new download task anyway
- Download is now running despite file already existing

**Expected Behavior:**
- System should detect existing downloaded files
- Should not create duplicate download tasks for content that's already been downloaded
- Should verify file existence before initiating new downloads

**Investigation Areas:**
1. File existence check in download monitor
2. Download deduplication logic
3. File path/naming consistency between existing files and new downloads
4. Background monitor's file scanning/tracking mechanism
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Implementation Summary

Fixed the background download monitor creating duplicate downloads by adding deduplication logic to the Downloads context.

### Root Cause
The automatic search jobs (MovieSearch and TVShowSearch) only checked for episodes/movies without media files, but didn't check if there was already an active download in progress. This caused the system to initiate a new download even when one was already running.

### Changes Made

1. **Added deduplication logic to `Downloads.initiate_download/2`** (lib/mydia/downloads.ex:287)
   - Added `check_for_duplicate_download/2` function that checks for existing active downloads before initiating a new one
   - Active downloads are those where `completed_at` is nil AND `error_message` is nil

2. **Implemented smart deduplication for different content types**:
   - **Episodes**: Checks if episode_id has an active download
   - **Movies**: Checks if media_item_id has an active download  
   - **Season Packs**: Checks if media_item_id has an active download with the same season_number in metadata
   - This allows downloading different seasons of the same show simultaneously

3. **Preserved season pack metadata** (lib/mydia/downloads.ex:429-460)
   - Updated `create_download_record/4` to merge season pack metadata (season_pack, season_number, episode_count) into the download record
   - This enables proper season pack deduplication

4. **Added comprehensive tests** (test/mydia/downloads_test.exs:457-641)
   - Tests for episode download deduplication
   - Tests for movie download deduplication
   - Tests for season pack deduplication (same vs different seasons)
   - Tests for allowing retries after failures or completions

### How It Works

When a download is initiated:
1. Check if episode_id or media_item_id is provided
2. Query database for active downloads (not completed, not failed)
3. For season packs, also check that season_number matches
4. If active download exists, return `{:error, :duplicate_download}`
5. Otherwise, proceed with adding torrent to client

### Files Modified
- lib/mydia/downloads.ex
- test/mydia/downloads_test.exs

### Testing
All deduplication tests pass successfully. The fix prevents duplicate downloads while still allowing legitimate retries after failures or completions.
<!-- SECTION:NOTES:END -->
