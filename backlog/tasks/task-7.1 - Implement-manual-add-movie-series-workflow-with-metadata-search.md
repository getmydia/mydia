---
id: task-7.1
title: Implement manual add movie/series workflow with metadata search
status: Done
assignee: []
created_date: '2025-11-04 16:31'
updated_date: '2025-11-04 16:38'
labels:
  - library
  - metadata
  - liveview
  - ui
  - core
dependencies:
  - task-23.1
  - task-23.2
  - task-7
  - task-32
parent_task_id: '7'
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Create the primary workflow for manually adding movies and TV shows to the library. Users search for media by title using metadata providers (via task-23.1 abstraction), select the correct match, configure monitoring and quality settings, and add to their library for tracking.

This is the core "Add New Movie" / "Add New Series" feature found in Sonarr/Radarr - add media to your library first, then the system automatically finds and downloads it later.

## Implementation Details

**UI Entry Points:**

1. **Library View Buttons**
   - "Add Movie" button in `/movies` view header
   - "Add Series" button in `/tv` view header  
   - Both open the add media modal/page

2. **Global Quick Add**
   - Quick add button in sidebar or mobile dock
   - Opens modal with media type selector

**Add Media Flow:**

1. **Search Step**
   - User enters search query (title, optionally year)
   - Call `Mydia.Metadata.search/2` using provider abstraction (task-23.1)
   - Shows loading state during search
   - Displays results in grid with posters

2. **Selection Step**
   - Grid of results with:
     - Poster image
     - Title and original title
     - Year
     - Overview (truncated)
     - Rating/popularity indicator
   - Click to select
   - "No match? Add manually" fallback option

3. **Configuration Step**
   - Selected media details displayed
   - Configuration form:
     - **Root Folder**: Dropdown of configured library paths (task-23.8)
     - **Quality Profile**: Dropdown from task-32 profiles
     - **Monitored**: Toggle (default: on)
     - **Search on Add**: Toggle to trigger immediate search (default: on, uses task-22.9)
     - For TV Shows:
       - Season monitoring options (all, future, none, first)
       - Specific seasons/episodes selector
   - Preview of final path: `/movies/The Matrix (1999)/`

4. **Confirmation Step**
   - Fetch full metadata using `Mydia.Metadata.fetch_by_id/2`
   - Create MediaItem with metadata
   - Create Episodes for TV shows
   - If "Search on Add" enabled, trigger manual search (task-22.9)
   - Show success message
   - Navigate to media detail page or back to library

**Manual Entry Fallback:**
- If no metadata match found or user selects "Add Manually"
- Form with fields: title, year, type, overview
- Creates MediaItem with user-provided data
- Can refresh metadata later

**TV Show Special Handling:**
- Fetch all seasons and episodes from metadata provider
- Create Episode records for monitored seasons
- Handle multi-season selections
- Air date checking for future episodes

**Context Modules:**
- `Mydia.Metadata` - Provider abstraction layer (task-23.1)
- `Mydia.Media` - Create MediaItem and Episodes
- `Mydia.Settings` - Get library paths and quality profiles
- `Mydia.Indexers` - Trigger search if "Search on Add" enabled

**LiveView Implementation:**
- `MydiaWeb.AddMediaLive` - Main add media LiveView
- Multi-step form with progress indicator
- Async metadata fetching
- Form validation and error handling
- Mobile-responsive design

**Integration Points:**
- Library paths from task-23.8
- Quality profiles from task-32
- Metadata providers from task-23.1, 23.2, 23.3
- Manual search trigger from task-22.9
- Media detail view from task-13
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Add Movie button in /movies view header
- [x] #2 Add Series button in /tv view header
- [x] #3 Search step uses Mydia.Metadata.search/2 abstraction
- [x] #4 Results displayed in grid with posters, titles, years
- [x] #5 Selection step shows media details for confirmation
- [x] #6 Configuration form with root folder, quality profile, monitoring toggle
- [x] #7 Search on Add toggle triggers manual search after creation
- [x] #8 TV shows: season monitoring options and selections
- [x] #9 Fetch full metadata and create MediaItem on confirmation
- [x] #10 For TV: create Episode records for monitored seasons
- [x] #11 Manual entry fallback for no metadata match
- [x] #12 Success message and navigation to media detail page
- [x] #13 Form validation and error handling
- [x] #14 Mobile-responsive multi-step interface
- [x] #15 Preview of final media path in configuration
<!-- AC:END -->
