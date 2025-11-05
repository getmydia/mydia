---
id: task-83
title: Add re-scan files button for TV show episodes
status: Done
assignee: []
created_date: '2025-11-05 18:45'
updated_date: '2025-11-05 18:52'
labels:
  - enhancement
  - ui
  - tv-shows
  - metadata
  - media-files
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
## Overview
Add season-level file metadata re-scanning for TV shows. Currently, task-78 implemented re-scan functionality at the series level (all files for the entire show), but TV shows would benefit from per-season re-scan options for more targeted maintenance.

## Current Situation
- Re-scan files button exists on media detail page for all media files (series-level) ✓ (from task-78)
- TV shows have multiple seasons with many episodes
- No way to re-scan files for a specific season
- Re-scanning entire series is overkill when only one season needs attention

## Proposed Solution

### Season-level Re-scan
Add a "Re-scan Season Files" button in the season collapse header:
- **Location**: Next to "Auto Search Season", "Manual Search", and "Monitor All" buttons
- **Behavior**: Scans all media files for episodes in that season only
- **Feedback**: Shows progress/count in toast (e.g., "Re-scanned 10 files in Season 1")
- **Icon**: Use same hero-arrow-path icon for consistency
- **Loading state**: Disable button and show spinner while scanning

### Implementation Details

**Template changes** (`lib/mydia_web/live/media_live/show.html.heex`):
```heex
<button
  type="button"
  phx-click="rescan_season_files"
  phx-value-season-number={season_num}
  class="btn btn-sm btn-ghost"
  disabled={@rescanning_season == season_num}
  title="Re-scan all file metadata for this season"
>
  <%= if @rescanning_season == season_num do %>
    <span class="loading loading-spinner loading-xs"></span> Re-scanning...
  <% else %>
    <.icon name="hero-arrow-path" class="w-4 h-4" /> Re-scan Files
  <% end %>
</button>
```

**LiveView changes** (`lib/mydia_web/live/media_live/show.ex`):
- Add `@rescanning_season` state tracking (similar to `@auto_searching_season`)
- Implement `handle_event("rescan_season_files", %{"season-number" => ...}, socket)`
- Filter media files by episodes in that season
- Use async processing pattern from task-78
- Update episode quality badges after completion

**Helper function**:
```elixir
defp get_season_media_files(media_item, season_number) do
  media_item.episodes
  |> Enum.filter(&(&1.season_number == season_number))
  |> Enum.flat_map(& &1.media_files)
end
```

## UI Layout
```
Season 1 [25 episodes] ▼
  [⚡ Auto Search Season] [🔍 Manual Search] [🔄 Re-scan Files] [★ Monitor All] [☆ Unmonitor All]
  
  Episode table...
```

## Benefits
- **Faster**: Re-scan only the season that needs attention
- **Targeted**: Fix metadata issues after replacing a season pack
- **Efficient**: Avoid re-scanning entire 10+ season series
- **Granular control**: Better for troubleshooting specific season quality issues

## Technical Considerations
- Reuse existing `Library.refresh_file_metadata/1` function
- Use same async pattern as task-78 (series-level re-scan)
- Handle seasons with no files gracefully (show appropriate message)
- Log operations with season number for debugging
- Consider progress tracking for large seasons (20+ episodes)

## Related
- Builds on task-78 (series-level re-scan for movies and TV shows)
- Complements existing season management features (monitor, search)
- Provides middle ground between series-level and episode-level granularity
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Season-level re-scan button visible in season collapse header next to other season actions
- [x] #2 Button triggers file metadata re-scan for all episodes in that season only
- [x] #3 Loading state shown with spinner while scanning
- [x] #4 Success toast message shows file count (e.g., 'Re-scanned 10 files in Season 1')
- [x] #5 Error handling shows which files failed if any
- [x] #6 Episode quality badges update after re-scan completes
- [x] #7 Button disabled during scan to prevent duplicate requests
- [x] #8 Works correctly for seasons with varying numbers of episodes (1-50+)

- [x] #9 Handles seasons with no media files gracefully (shows info message)
- [x] #10 Uses same async pattern as task-78 for consistency
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Implementation Summary

Successfully implemented season-level file re-scanning for TV shows. This feature provides a middle ground between series-level re-scan (all files) and episode-level management.

### Changes Made

**1. Template Changes** (`lib/mydia_web/live/media_live/show.html.heex`)
- Added "Re-scan Season Files" button in season collapse header (line 284-298)
- Button positioned between "Manual Search" and "Monitor All" buttons
- Shows loading spinner during scan with disabled state
- Uses hero-arrow-path icon for consistency with series-level button

**2. LiveView State** (`lib/mydia_web/live/media_live/show.ex`)
- Added `@rescanning_season` assign to track which season is being rescanned (line 63)
- Similar pattern to `@auto_searching_season` for consistency

**3. Event Handler** (`lib/mydia_web/live/media_live/show.ex:228-246`)
- Implemented `handle_event("rescan_season_files", ...)` 
- Parses season number from params
- Retrieves season-specific media files via helper function
- Handles empty file list gracefully with info message
- Starts async task with season number context

**4. Async Handler** (`lib/mydia_web/live/media_live/show.ex:972-1003`)
- Three pattern-matched handlers for success, error, and exit cases
- Success handler shows count with season context
- Reloads media item to update episode quality badges
- Resets `@rescanning_season` state after completion
- Error messages include season number for clarity

**5. Helper Function** (`lib/mydia_web/live/media_live/show.ex:1565-1569`)
- `get_season_media_files/2` filters episodes by season number
- Uses `Enum.flat_map` to collect all media files from matching episodes
- Returns flat list of media files ready for processing

### Technical Implementation

The implementation follows the same async pattern as task-78's series-level re-scan:

1. User clicks "Re-scan Season Files" button
2. `handle_event` validates season has files and starts async task
3. Async task calls existing `refresh_files/1` function
4. `handle_async` processes results and shows appropriate message
5. Media item is reloaded to update UI with fresh metadata
6. Loading state is cleared and button re-enabled

### Benefits

- **Targeted**: Re-scan only the season that needs attention
- **Efficient**: Avoids re-scanning entire multi-season series
- **Consistent**: Uses same patterns and UI elements as existing features
- **Reliable**: Proper error handling and user feedback

### Testing Notes

- Code compiles successfully
- Formatter applied correctly
- All acceptance criteria verified through code review
- Pattern matches existing series-level implementation
<!-- SECTION:NOTES:END -->
