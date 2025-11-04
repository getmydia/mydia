---
id: task-22.10
title: Implement automatic background search for monitored media
status: To Do
assignee: []
created_date: '2025-11-04 16:02'
labels:
  - automation
  - oban
  - jobs
  - search
  - downloads
dependencies:
  - task-22.9
  - task-29
  - task-32
  - task-21.4
  - task-21.7
  - task-8
parent_task_id: '22'
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Create Oban background jobs that automatically search for and download releases for monitored movies and TV shows. This is the core automation feature that makes Mydia "set and forget" - users add media to their library, and the system automatically finds and downloads new releases.

This implements the automatic acquisition workflow: monitored media → periodic searches → quality profile matching → automatic download → import to library.

## Implementation Details

**Oban Jobs:**

1. **MovieSearchJob** - Search for monitored movies
   - Runs on configurable schedule (default: every 30 minutes)
   - Query monitored movies missing files or below quality cutoff
   - For each movie, search indexers with constructed query
   - Evaluate results against quality profile
   - Auto-download best matching release (if configured)
   - Log search results and decisions

2. **TVShowSearchJob** - Search for monitored TV episodes
   - Runs on configurable schedule (default: every 15 minutes for recently aired, hourly for older)
   - Query monitored TV shows for:
     - Missing episodes (aired but not downloaded)
     - Upcoming episodes (within 24 hours of airing)
     - Episodes below quality cutoff (upgrade eligible)
   - For each episode, search indexers
   - Evaluate and auto-download best match
   - Handle season packs (download entire season if better than individual episodes)

3. **RSSFeedJob** (optional/future) - Monitor indexer RSS feeds
   - Runs every 5-15 minutes
   - Check RSS feeds from indexers that support it
   - Parse new releases
   - Match against monitored media using title parsing
   - Auto-download matches

**Search Strategy:**
- Construct precise queries: "Movie Title (Year)" or "Show S##E##"
- Use quality profile filters in initial search when possible
- Fall back to broader search if no results
- Respect indexer rate limits from task-22.7

**Auto-Download Decision Logic:**
- Check if release matches quality profile requirements
- Verify size constraints
- Check for blocked tags
- Compare to existing file quality (if any)
- Only download if improvement or meeting cutoff
- Respect "preferred" settings (wait for preferred before downloading)

**Configuration Options (in Settings):**
- Enable/disable automatic search globally
- Search intervals for movies and TV
- Automatic download enabled (or search only, manual approval)
- RSS monitoring enabled
- Quality profile requirements before auto-download

**Error Handling:**
- Indexer failures don't block other indexers
- Download client errors logged and retried
- Failed searches scheduled for retry with backoff
- Notification/alert system for repeated failures

**Performance:**
- Batch queries to avoid overwhelming indexers
- Distributed processing across Oban workers
- Configurable concurrency limits
- Respect rate limits per indexer

**Integration:**
- Uses manual search logic from task-22.9
- Uses download initiation from task-29
- Uses quality profile matching from task-32
- Uses download monitoring from task-21.4
- Uses import workflow from task-21.7
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 MovieSearchJob searches for monitored movies missing files
- [ ] #2 TVShowSearchJob searches for monitored episodes (missing, upcoming, upgrades)
- [ ] #3 Jobs run on configurable schedules
- [ ] #4 Search queries constructed from media metadata
- [ ] #5 Results evaluated against quality profile preferences
- [ ] #6 Automatic download of best matching release (if enabled)
- [ ] #7 Season pack detection and handling for TV shows
- [ ] #8 Respects indexer rate limits from configurations
- [ ] #9 Configuration options for intervals and auto-download behavior
- [ ] #10 Error handling with retry logic and backoff
- [ ] #11 Performance optimizations (batching, concurrency limits)
- [ ] #12 Logging of all search attempts and download decisions
- [ ] #13 Integration with manual search, download, and import workflows
<!-- AC:END -->
