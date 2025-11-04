---
id: task-41
title: Fix list view toggle breaking media items display in media library
status: Done
assignee:
  - assistant
created_date: '2025-11-04 20:59'
updated_date: '2025-11-04 21:24'
labels:
  - bug
  - ui
  - liveview
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The media library LiveView has a bug where switching between grid and list views causes items to disappear:

**Current Behavior:**
- Grid view works correctly on initial page load and displays all media items
- Switching from grid to list view shows no items (empty state)
- Switching back to grid view also shows nothing, even though it worked initially
- The view appears broken after any toggle operation

**Expected Behavior:**
- Media items should display correctly in both grid and list views
- Switching between views should preserve the media items display
- Both views should show the same media items, just with different layouts

**Technical Context:**
- Related to task-7 (Build media library LiveView with grid and list views) which is marked as Done
- Likely a state management or rendering issue in the LiveView
- May involve LiveView streams, phx-update attributes, or view mode state handling

**Investigation Areas:**
- Check how view mode state is tracked in the LiveView
- Verify LiveView streams are properly configured for both view modes
- Inspect phx-update attributes and DOM ID handling
- Review event handlers for view toggle
- Check if template conditionals are correctly handling both view modes
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Grid view displays all media items correctly on initial page load
- [x] #2 Switching to list view displays all media items in list format
- [x] #3 Switching from list view back to grid view preserves all media items
- [x] #4 Multiple toggles between grid and list views work without losing items
- [x] #5 No console errors or Phoenix LiveView errors occur during view switching
- [x] #6 Empty state only shows when there are genuinely no media items
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
## Approved Implementation Plan

### Root Cause
Grid view and list view use different container IDs (`media-grid` vs `media-list`) with `phx-update="stream"`. When toggling views, the container is destroyed and recreated with a different ID, causing LiveView to lose the stream state.

### Solution: Single Parent Container
Use a single parent container ID for both views so stream state persists across view toggles.

### Implementation Steps
1. Wrap both grid and list views in a single parent `<div id="media-items" phx-update="stream">`
2. Move conditional rendering inside the stream container
3. Keep view-specific layouts but ensure they share the same stream parent
4. Test all acceptance criteria to ensure the fix works correctly

### Files to modify
- `lib/mydia_web/live/media_live/index.html.heex` - Refactor template structure (lines 100-256)
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Implementation Complete

### Changes Made
Refactored `lib/mydia_web/live/media_live/index.html.heex` to fix stream container ID conflicts:

1. **Unified container ID**: Both views now use `id="media-items"` on their stream containers
   - Grid view: `<div id="media-items" phx-update="stream">` (line 118)
   - List view: `<tbody id="media-items" phx-update="stream">` (line 181)

2. **Fixed list view structure**: Moved `phx-update="stream"` from `<table>` to `<tbody>` so stream items (`<tr>` elements) are direct children of the stream container (required by LiveView)

3. **Extracted empty state**: Moved empty state rendering outside both view conditionals to prevent duplication and ensure it's always visible when appropriate

4. **Fixed infinite scroll**: Moved `phx-viewport-bottom="load_more"` for list view to the wrapper div

### Why This Fixes The Bug
- Previously, grid used `id="media-grid"` and list used `id="media-list"` on different element types
- When toggling views, the old container was destroyed and a new one with a different ID was created
- LiveView's stream tracking lost state because the stream container ID changed
- Now both views use the same ID (`media-items`), so LiveView maintains stream state across view toggles
- Since only one view is rendered at a time, there's no ID conflict in the DOM

### Testing
- Code compiles successfully with no errors
- Template syntax is valid
- Ready for manual testing in browser

## Second Implementation (Correct Fix)

### Problem with First Attempt
The first fix failed because even with the same ID, the containers were destroyed and recreated when switching views due to the `<%= if @view_mode ... %>` conditionals. LiveView streams require the container to persist in the DOM.

### Final Solution: Persistent Containers with CSS Hide/Show
Both stream containers now exist in the DOM simultaneously and are shown/hidden with CSS.

### Changes Made
1. **Grid container**: Always rendered with `id="media-items-grid"`, hidden when `@view_mode != :grid`
2. **List container**: Always rendered with `id="media-items-list"`, hidden when `@view_mode != :list`
3. **Unique IDs**: Grid items use `"#{id}-grid"`, list items use `"#{id}-list"` to avoid duplicate DOM IDs
4. **Both containers consume the same stream**: `@streams.media_items` is iterated by both containers

### Why This Works
- Both `phx-update="stream"` containers persist in the DOM continuously
- When view mode changes, LiveView only toggles CSS classes (hidden/visible)
- Stream state is maintained independently for each container
- No DOM destruction/recreation, so no data loss
- Valid HTML with no duplicate IDs (suffixes ensure uniqueness)

### Code compiles successfully
- Ready for manual testing in browser

## Completion Confirmed

✅ Manual testing completed successfully by user
✅ Grid and list views now maintain items when toggling
✅ All acceptance criteria verified and passing

The persistent container approach with CSS hide/show successfully fixed the stream state loss issue.
<!-- SECTION:NOTES:END -->
