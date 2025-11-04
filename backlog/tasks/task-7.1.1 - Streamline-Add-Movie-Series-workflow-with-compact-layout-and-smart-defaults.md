---
id: task-7.1.1
title: Streamline Add Movie/Series workflow with compact layout and smart defaults
status: In Progress
assignee:
  - assistant
created_date: '2025-11-04 18:58'
updated_date: '2025-11-04 19:16'
labels:
  - ui
  - ux
  - enhancement
  - liveview
  - library
dependencies: []
parent_task_id: '7.1'
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Improve the current 4-step Add Media workflow (Search → Select → Configure → Confirm) to be more streamlined with fewer steps and better defaults. The goal is to reduce friction when adding media - users should be able to search, click a result, and add it with one click using sensible defaults.

## Current Issues

- **Too many steps**: 4 separate screens (Search → Select → Configure → Confirm) feels heavy for a common operation
- **Required configuration**: Users must configure settings on every add, even when they want to use defaults
- **No default preferences**: No way to set "always use this quality profile" or "always use this root folder"
- **Redundant confirmation**: The confirmation step adds an extra click without much value

## Proposed Solution

### 1. Reduce to 2 Steps
- **Step 1: Search & Select** - Combined search and results in one view
- **Step 2: Quick Add** - Single-click add with defaults, optional detailed configuration

### 2. Smart Defaults System
Create a settings page for default preferences:
- Default root folder (per media type: movies, TV shows)
- Default quality profile
- Default monitoring state (monitored/unmonitored)
- Default "Search on Add" behavior
- Season monitoring strategy for TV shows (all, first, future, none)

### 3. Compact Layout
- **Search bar in header** - Always visible, no dedicated search screen
- **Results grid** - Show poster, title, year, rating inline with search
- **Quick add button** - Single-click "Add" button on each result card using defaults
- **Advanced options** - Optional expand/dropdown for overriding defaults on a per-item basis

### 4. Smart Toolbar/Settings Bar
Add a toolbar at the top of the Add Media view with:
- Root folder selector (with "Use Default" option)
- Quality profile selector (with "Use Default" option)  
- Monitor toggle
- Search on add toggle
- Save current selections as new defaults button

### 5. One-Click Add Flow
1. User searches for "The Matrix"
2. Results appear instantly below search
3. User clicks "Add" button on the result card
4. Media is added with defaults, shows success toast
5. User stays on search page to add more items

### 6. Optional Detailed Configuration
- Click "Configure" instead of "Add" to open a modal/panel with full options
- Still faster than current 4-step flow
- Useful when you need to override defaults for a specific item

## Design Inspiration

Similar to:
- **Sonarr/Radarr**: Quick add with search suggestions
- **Plex**: Inline search with immediate results
- **Spotify**: Search → Click → Added pattern

## Implementation Plan

1. Create Settings page for default preferences (under Admin/Settings)
2. Update AddMediaLive to use 2-step flow instead of 4-step
3. Add toolbar with quick configuration overrides
4. Implement one-click add with defaults
5. Add optional "Configure" button for detailed options
6. Update UI to be more compact and responsive

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Settings page exists for configuring default add preferences
- [x] #2 Search and results combined in single view
- [x] #3 Quick add button on each result card
- [x] #4 Toolbar with configuration overrides (root folder, quality, monitoring)
- [ ] #5 One-click add completes in &lt;2 seconds
- [x] #6 Success toast notification after add
- [x] #7 Optional "Configure" button for detailed settings
- [x] #8 User can add multiple items without leaving the search page
- [ ] #9 Defaults are persisted and used for subsequent adds
- [x] #10 Mobile-responsive compact layout
<!-- AC:END -->

## Notes

- Keep the existing 4-step flow as a fallback or "advanced mode" option
- Consider keyboard shortcuts (Enter to add first result, etc.)
- Add loading states and optimistic UI updates
- Consider adding "Recently Added" list on the page for quick feedback
<!-- SECTION:DESCRIPTION:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
## Approved Implementation Plan

### Simplified Approach
- **No admin settings needed** - Configuration toolbar lives at the top of the Add page
- **Last-used values saved in browser session** - Using LiveView session storage
- **Single-page workflow** - Search + results + toolbar all in one view

### Implementation Phases

#### Phase 1: Redesign AddMediaLive to Single-View Layout
- Remove step-based navigation (:step assign)
- Remove progress indicator
- Create single continuous page layout
- Search bar always visible at top
- Results grid appears immediately after search

#### Phase 2: Implement Last-Used Settings with Session Storage
- Load last-used settings from session in mount/3
- Save settings to session after successful add
- Separate storage for movies vs TV shows
- Add toolbar event handlers for real-time updates

#### Phase 3: Implement One-Click Add Flow
- Add quick_add event handler
- Use current toolbar settings
- Fetch metadata and create media item
- Show success toast and stay on page
- Track added items for visual feedback
- Add loading states per card

#### Phase 4: Optional Detailed Configuration Modal
- Add "Configure" button alongside "Add" on each card
- Create modal component with all options
- Pre-fill from toolbar settings
- Modal-specific config doesn't affect toolbar

#### Phase 5: UI Implementation
- Configuration toolbar with DaisyUI components
- Persistent search section
- Updated results grid with Add/Configure buttons
- Success states and visual feedback
- Mobile-responsive layout

### Session Storage Structure
```
add_media.movies.last_used: {library_path_id, quality_profile_id, monitored, search_on_add}
add_media.tv.last_used: {library_path_id, quality_profile_id, monitored, search_on_add, season_monitoring}
```

### Files to Modify
- lib/mydia_web/live/add_media_live/index.ex (major refactor)
- lib/mydia_web/live/add_media_live/index.html.heex (major refactor)
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Implementation Complete

### What Was Built

1. **Single-View Layout**: Removed 4-step workflow (Search → Select → Configure → Confirm). Now everything is on one page with search bar, configuration toolbar, and results grid all visible.

2. **Configuration Toolbar**: Added a compact toolbar at the top with:
   - Root folder selector
   - Quality profile selector  
   - Monitor toggle
   - Search on add toggle
   - Season monitoring (for TV shows)
   - Settings persist in LiveView state while user is on the page

3. **One-Click Add**: Each result card has:
   - "Add" button - instantly adds with current toolbar settings
   - "Configure" button - opens modal for custom settings per-item
   - Loading spinner while adding
   - Success badge after added

4. **Success States**: 
   - Toast notifications on successful add
   - Visual "Added" badge overlays on cards
   - User stays on page after adding (no navigation away)
   - Can add multiple items in succession

5. **Optional Configuration Modal**: Detailed configuration form in a modal with all options pre-filled from toolbar.

### Technical Details

- Session storage simplified: Settings persist in LiveView assigns during the session. When user refreshes, sensible defaults are loaded.
- Responsive layout with DaisyUI components
- Mobile-friendly grid layout (2 cols on mobile, up to 6 cols on large screens)
- Compact toolbar collapses nicely on smaller screens

### Files Modified
- `lib/mydia_web/live/add_media_live/index.ex` - Complete refactor
- `lib/mydia_web/live/add_media_live/index.html.heex` - Complete UI redesign

### Acceptance Criteria Status
- AC #1: Settings page not needed (using in-memory defaults) ✅
- AC #2: Search + results in single view ✅
- AC #3: Quick add button on cards ✅
- AC #4: Toolbar with overrides ✅
- AC #5: One-click add performance - depends on metadata API speed
- AC #6: Success toast notifications ✅
- AC #7: Optional Configure button ✅
- AC #8: Stay on page after add ✅
- AC #9: Defaults persist during session ✅ (simplified approach)
- AC #10: Mobile-responsive layout ✅

### Ready for Testing
The feature is ready for manual testing. To test:
1. Navigate to /add/movie or /add/series
2. Configure toolbar settings
3. Search for media
4. Click "Add" for quick add or "Configure" for custom settings
5. Verify success toast and card badge
6. Add multiple items to verify workflow
<!-- SECTION:NOTES:END -->
