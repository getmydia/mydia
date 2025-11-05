---
id: task-81
title: Add manual search for TV show season
status: Done
assignee: []
created_date: '2025-11-05 18:37'
updated_date: '2025-11-05 18:42'
labels:
  - enhancement
  - ui
  - search
  - tv-shows
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Add the ability to manually search for and download an entire TV show season, similar to the existing manual search functionality for individual episodes and movies.

## Current Situation
- Manual search exists for movies (searches for the entire movie)
- Manual search exists for individual episodes (searches for specific episode)
- No manual search option for an entire season
- Users must search for each episode individually or use auto-search

## Proposed Solution

### UI Changes
Add a "Manual Search" button at the season level in the TV show detail page:
- Location: In the season header/card, alongside season-level actions
- Behavior: Opens the manual search modal pre-configured for the season

### Search Query Building
Build season-specific search queries:
- Format: "{Show Title} S{season_number}" (e.g., "Robin Hood S01")
- Consider year for disambiguation if needed
- Support both season packs and individual episode results

### Search Results Display
Enhanced result filtering and display:
- Show season pack releases prominently (torrents containing all episodes)
- Also show individual episode releases as fallback
- Indicate which results are complete season packs vs individual episodes
- Filter by season number to avoid showing wrong season results

### Download Handling
Support different download scenarios:
- Season pack download: Associate with all episodes in the season
- Individual episode downloads: Associate with specific episodes
- Track which episodes are covered by each download

### Manual Search Modal Enhancement
Extend existing modal to support season context:
- Add season_number to search context
- Display "Searching for: {Show Title} - Season {N}" in modal header
- Filter results by season relevance
- Add quality and size sorting for season packs

## Technical Implementation

### Search Context
```elixir
%{
  media_item_id: media_item.id,
  season_number: 1,
  search_type: :season
}
```

### Query Building
```elixir
def build_season_search_query(media_item, season_number) do
  base_query = "#{media_item.title} S#{String.pad_leading("#{season_number}", 2, "0")}"
  
  if media_item.year do
    "#{base_query} #{media_item.year}"
  else
    base_query
  end
end
```

### Result Association
- Season packs should be associated with the media_item_id (not a specific episode)
- When download completes, match files to episodes during import
- Use existing TorrentMatcher to identify which episodes are in the download

## User Flow
1. User navigates to TV show detail page
2. Clicks "Manual Search" button at season level (e.g., for Season 1)
3. Modal opens with season-specific search query
4. Results show season packs + individual episodes for that season
5. User selects desired release (season pack preferred)
6. Download is initiated and associated with the season/show
7. When complete, files are matched to individual episodes

## Benefits
- Faster workflow for downloading complete seasons
- Better quality control (season packs often have consistent quality)
- Reduces need for multiple searches per season
- Complements auto-search for manual quality selection

## Related Features
- Builds on existing manual search modal infrastructure
- Uses existing search result ranking/filtering
- Integrates with TorrentMatcher for episode association
- Works alongside auto-search functionality
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Manual Search button visible at season level on TV show detail page
- [x] #2 Button opens manual search modal with season-specific query (e.g., 'Show Name S01')
- [x] #3 Search results display season packs and individual episodes for the selected season
- [x] #4 Season pack results are clearly marked/distinguished from individual episodes
- [x] #5 User can download season pack and it associates with all episodes in that season
- [x] #6 Search modal header displays season context (e.g., 'Searching for: Robin Hood - Season 1')
- [x] #7 Results can be filtered/sorted by quality, size, and seeders
- [x] #8 Downloaded season packs are tracked and associated with the correct season
- [x] #9 Manual season search works for all seasons of a TV show
- [x] #10 Quality and source filters work correctly for season search results
<!-- AC:END -->
