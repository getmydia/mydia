---
id: task-31
title: Implement add to library workflow from discovery search
status: In Progress
assignee: []
created_date: '2025-11-04 16:00'
updated_date: '2025-11-04 21:20'
labels:
  - library
  - metadata
  - liveview
  - ui
  - search
dependencies:
  - task-22.8
  - task-23.5
  - task-23.6
  - task-23.1
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Complete the stubbed "add to library" functionality in the discovery search view. Parse the release title, match it to TMDB/TVDB, create a MediaItem with full metadata, and optionally download the selected release.

This is the bridge between discovery and library management: user finds interesting media on indexers → adds it to their library for tracking/monitoring → optionally downloads it immediately.

## Implementation Details

The add to library button handler exists at `lib/mydia_web/live/search_live/index.ex:107-113` with a TODO placeholder.

**Add to Library Flow:**
1. User clicks "add to library" on a search result
2. Parse release title using filename parser (task-23.5) to extract:
   - Media title and year (for movies)
   - Series name, season, episode (for TV shows)
   - Quality information (already parsed in SearchResult)
3. Search TMDB/TVDB for matching media using extracted metadata
4. If multiple matches, show disambiguation modal with poster/year/description
5. User confirms match
6. Create MediaItem (and Episodes for TV) with full metadata from provider
7. Set as monitored by default (user can toggle)
8. Optionally download the selected release immediately (trigger task-29)
9. Show success message and redirect to media detail page

**TV Shows Handling:**
- Create or find existing TV show MediaItem
- Create Episode records for the specific episode(s) in the release
- Associate with the show's seasons

**Error Handling:**
- No metadata match found (allow manual entry)
- Ambiguous matches (require user selection)
- Metadata provider API errors
- Release title parsing failures

**Context Modules:**
- `Mydia.Media` - Create MediaItem and Episodes
- `Mydia.Indexers.TitleParser` - Parse release titles (task-23.5)
- `Mydia.Metadata` - Search and fetch from TMDB/TVDB (task-23.2/23.3)
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Parses release title to extract media name, year, season/episode
- [x] #2 Searches metadata provider (TMDB/TVDB) for matching media
- [ ] #3 Shows disambiguation modal when multiple matches found
- [x] #4 Creates MediaItem with full metadata (title, year, poster, overview, etc.)
- [x] #5 For TV shows, creates series + episode records
- [x] #6 Sets newly added media as monitored by default
- [ ] #7 Option to download the selected release immediately
- [x] #8 Shows success message and navigates to media detail page
- [ ] #9 Handles parsing failures gracefully (manual entry fallback)
- [ ] #10 Handles metadata provider errors with retry option
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Implementation Update

This task should use the metadata provider abstraction layer (task-23.1) instead of directly calling TMDB/TVDB APIs. The flow becomes:

1. Parse release title using `Mydia.Indexers.TitleParser` (task-23.5)
2. Search metadata using `Mydia.Metadata.search/2` abstraction
3. Use metadata matching logic from task-23.6 to find best match
4. Fetch full metadata with `Mydia.Metadata.fetch_by_id/2`
5. Create MediaItem with normalized metadata struct

This ensures consistency with task-7.1 (manual add workflow) and keeps the codebase flexible to different metadata providers.

## Implementation Progress

### Completed (2025-01-04)

**Core add to library workflow implemented in SearchLive.Index:**

1. ✅ Parse release title using FileParser.parse/1
   - Extracts title, year, season, episode numbers, quality info
   - Handles both movie and TV show formats
   - Returns confidence score for match quality

2. ✅ Search metadata provider using Metadata.search/3
   - Uses default metadata relay configuration
   - Searches by media type (movie or tv_show)
   - Includes year filter when available

3. ✅ Fetch full metadata using Metadata.fetch_by_id/3
   - Takes first search match (disambiguation UI pending)
   - Fetches complete metadata including poster, overview, cast, etc.

4. ✅ Create MediaItem from metadata
   - Builds attrs from parsed release and metadata
   - Checks for existing media by TMDB ID to avoid duplicates
   - Sets monitored: true by default
   - Stores full metadata in JSONB field

5. ✅ For TV shows, create Episode records
   - Creates episodes for season/episode numbers from release
   - Handles multi-episode releases (e.g., S01E01-E03)
   - Skips episodes that already exist

6. ✅ Error handling
   - Parse failures (low confidence, unknown type)
   - No metadata matches found
   - Metadata provider errors
   - Database errors on create

7. ✅ Success flow
   - Shows flash message with media title
   - Navigates to media detail page

**Location:** `lib/mydia_web/live/search_live/index.ex:126-527`

### Pending Work

- Disambiguation modal UI for multiple metadata matches
- Integration tests for the full workflow
- Manual entry fallback when parsing fails
<!-- SECTION:NOTES:END -->
