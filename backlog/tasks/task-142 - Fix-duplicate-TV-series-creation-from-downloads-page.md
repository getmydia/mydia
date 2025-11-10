---
id: task-142
title: Fix duplicate TV series creation from downloads page
status: To Do
assignee: []
created_date: '2025-11-10 18:10'
labels:
  - bug
  - tv-shows
  - duplicates
  - downloads
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
When adding a TV show from the downloads/search page, the system creates a duplicate series instead of detecting and using an already existing series in the library.

## Current Behavior
- User searches for "Bluey" 
- User clicks to add/download a Bluey episode
- System creates a new duplicate "Bluey" series entry even though Bluey already exists in the library

## Expected Behavior
- System should detect existing TV series by metadata ID (TMDB/TVDB/IMDB)
- If series already exists, use the existing record and just add the episode/season
- Only create new series if it doesn't exist in library

## Impact
- Creates duplicate library entries
- Confuses media organization
- May cause metadata conflicts

## Investigation Needed
- Check the add-to-library flow from search/downloads page
- Verify duplicate detection logic for TV series
- Ensure TMDB/metadata matching works correctly
- Check if this only affects search page or other flows too

## Related Code Areas
- `lib/mydia_web/live/search_live/index.ex` - Search page add-to-library flow
- `lib/mydia/library.ex` - Library management and duplicate detection
- TV series creation and matching logic
<!-- SECTION:DESCRIPTION:END -->
