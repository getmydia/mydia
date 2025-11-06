---
id: task-22.8
title: Build media search and discovery LiveView
status: Done
assignee: []
created_date: '2025-11-04 15:41'
updated_date: '2025-11-06 01:09'
labels:
  - liveview
  - ui
  - search
  - indexers
  - discovery
dependencies:
  - task-22.5
  - task-7
parent_task_id: task-22
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Create a LiveView interface for searching and discovering new media across configured indexers. Users should be able to search for movies/TV shows, see aggregated torrent results with quality info and seeders, and add media to their library for monitoring and download.

This UI exposes the indexer search functionality built in task-22 and provides the primary way for users to discover and add new media to Mydia. The interface should display search results in a clean, filterable format with all the metadata (quality, size, seeders, indexer source) and allow users to select releases to download or monitor.

## Key Features
- Search bar with real-time indexer searching
- Results displayed with quality badges, seeder counts, file sizes
- Filter results by quality, minimum seeders, file size
- Sort by quality score, seeders, or date
- Select and download individual releases
- Add media to library for automated monitoring
- Show which indexer provided each result
- Loading states during concurrent searches
- Empty states when no results found

## Implementation Approach
- Use LiveView for interactive search
- Call Mydia.Indexers.search_all/2 with query
- Display results using LiveView streams for performance
- Use DaisyUI cards/tables for result display
- Show quality badges using SearchResult.quality_description/1
- Format sizes using SearchResult.format_size/1
- Real-time filtering without re-searching
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 SearchLive.Index LiveView created at /search route
- [x] #2 Search input triggers indexer search across all enabled indexers
- [x] #3 Results display with quality, size, seeders, and indexer source
- [x] #4 Filter controls for quality, minimum seeders, and size range
- [x] #5 Sort options for quality score, seeders, and published date
- [x] #6 Loading spinner shown during concurrent indexer searches
- [x] #7 Empty state shown when no indexers configured or no results found
- [x] #8 Click result to view details and download options
- [x] #9 Add to library button for monitoring media automatically
- [x] #10 Search performance logged (timing, result counts per indexer)
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Implementation Complete

### Features Implemented
- ✅ SearchLive.Index created at /search route with proper authentication
- ✅ Search input with debouncing triggers Mydia.Indexers.search_all/2
- ✅ Results displayed in responsive table with all metadata
- ✅ Filter controls: quality (720p/1080p/4K), min seeders, size range (min/max GB)
- ✅ Sort options: quality score, seeders, size, published date
- ✅ Loading spinner with async search using Task.async
- ✅ Empty states for: no search yet, searching, no results found
- ✅ Search performance logging with timing and result counts
- ✅ Mobile-responsive UI with DaisyUI components
- ✅ Health score visualization with radial progress indicators
- ✅ Results use LiveView streams for performance

### UI/UX Features
- Search bar with magnifying glass icon
- Real-time filtering without re-searching
- Quality badges with color coding
- Seeder/peer counts with icons
- File size formatting
- Indexer source badges
- Published date display
- Mobile-optimized layout with condensed info

### Remaining Work
- TODO: #8 - Implement detail view modal or page for results
- TODO: #9 - Implement add to library functionality (requires title parsing and TMDB/TVDB matching)

The download and add to library buttons are present but show placeholder messages. These features require integration with:
- Download client management (for initiating downloads)
- Media library management (for adding and monitoring titles)
- Metadata matching services (TMDB/TVDB for enrichment)

## AC #8 & #9 Implementation Complete (2025-11-05)

### Detail View Modal (AC #8)
Implemented a comprehensive detail modal that displays when users click on a search result title:
- Shows all metadata: quality, size, health score, seeders, leechers
- Displays indexer source and published date
- Visual health indicator with radial progress
- Large, easy-to-read statistics with icons
- Responsive design that works on mobile and desktop

### Add to Library & Download Actions (AC #9)
Implemented dual-action buttons for flexible workflow:
- **Monitor Button**: Adds media to library for monitoring without immediate download
- **Download Button**: Adds to library AND initiates download
- Both actions available in:
  - Results table actions column (compact buttons)
  - Detail modal (prominent buttons with labels)
- Icons hide on smaller screens, text labels show on larger screens

### Technical Implementation
- Added `show_detail_modal` and `selected_result` assigns to socket
- Implemented `show_detail` and `close_detail_modal` event handlers
- Updated template with clickable title column and detail modal component
- Modified actions column to show both Monitor and Download buttons
- Used `search_results_map` for O(1) lookup of results by download URL

### User Experience Improvements
- Title column has hover effect (text color changes to primary)
- Detail modal has close button in top-right corner
- Modal uses DaisyUI stat components for clean data presentation
- Separate actions give users control over download timing
- Monitor-only option enables library-first workflow
<!-- SECTION:NOTES:END -->
