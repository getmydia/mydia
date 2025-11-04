---
id: task-22.9
title: Implement manual search for existing library media items
status: To Do
assignee: []
created_date: '2025-11-04 16:01'
labels:
  - library
  - search
  - liveview
  - ui
dependencies:
  - task-13
  - task-22.8
  - task-29
parent_task_id: '22'
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Create a manual search interface for movies and TV episodes already in the library. This is the acquisition workflow (as opposed to the discovery search): user triggers a search for a specific media item they already own/monitor, sees available releases, and downloads the best one.

This enables users to manually find and download releases for media in their library, either because automatic search didn't find anything suitable or because they want to upgrade quality.

## Implementation Details

**UI Location:**
- Media detail page (task-13): "Search" button triggers manual search
- Episode list view for TV shows: "Search" icon per episode

**Manual Search Flow:**
1. User clicks "Search" button on a media item or episode
2. System constructs search query from known metadata:
   - Movies: "Title (Year)" e.g. "The Matrix (1999)"
   - TV Episodes: "Series S##E##" e.g. "Breaking Bad S01E01"
3. Call `Mydia.Indexers.search_all/2` with constructed query
4. Filter results using quality profile preferences (if assigned)
5. Display results in modal or dedicated search results section
6. Results show quality match indicators (matches profile, upgrade available, etc.)
7. User selects a release and clicks download
8. Download is initiated (task-29) and associated with the media_item_id or episode_id
9. Download monitor job (task-21.4) tracks completion
10. Import workflow (task-21.7) associates completed files with media item

**Quality Profile Integration:**
- If media item has quality profile assigned, highlight matching releases
- Show "upgrade" badge on releases better than current quality
- Option to auto-select best matching release

**Reuse Discovery Search UI:**
- Use same SearchResult display components from task-22.8
- Similar filter/sort options
- Different context (searching for known item vs discovery)

**Context Modules:**
- `Mydia.Media` - Get media item details
- `Mydia.Indexers` - Search with constructed queries
- `Mydia.Downloads` - Initiate download with media association
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Manual search button on media detail page
- [ ] #2 Manual search button/icon on episode rows for TV shows
- [ ] #3 Constructs appropriate search query from media metadata
- [ ] #4 Searches all enabled indexers using constructed query
- [ ] #5 Displays results in modal or search section with full metadata
- [ ] #6 Shows quality profile match indicators (matches, upgrade, etc.)
- [ ] #7 Download button associates download with media_item_id or episode_id
- [ ] #8 Filter and sort options similar to discovery search
- [ ] #9 Handles no results found gracefully
- [ ] #10 Shows search history for the media item
<!-- AC:END -->
