---
id: task-23.6
title: Implement metadata matching and enrichment engine
status: To Do
assignee: []
created_date: '2025-11-04 03:39'
updated_date: '2025-11-04 03:39'
labels:
  - library
  - metadata
  - matching
  - backend
dependencies:
  - task-23.1
  - task-23.2
  - task-23.5
parent_task_id: task-23
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Create the matching engine that takes parsed file information and finds the corresponding entry in metadata providers (TMDB/TVDB via relay). The engine should use fuzzy matching, handle title variations, and provide confidence scores.

Once matched, enrich the media_items and episodes tables with full metadata including descriptions, posters, backdrops, cast, crew, ratings, genres, etc. Store images locally or reference external URLs based on configuration.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Matching uses title and year for movies with fuzzy string comparison
- [ ] #2 TV show matching uses series name and season/episode numbers
- [ ] #3 Multiple match candidates are ranked by confidence score
- [ ] #4 Automatic matching accepts high-confidence matches (>90%)
- [ ] #5 Low-confidence matches are flagged for manual review
- [ ] #6 Metadata is stored in media_items.metadata JSON field
- [ ] #7 Images (posters, backdrops) are downloaded and stored or URLs are cached
- [ ] #8 Episode metadata is fetched for TV shows and stored in episodes table
- [ ] #9 Matching can be retried with different search terms
- [ ] #10 Manual match override is supported via API
<!-- AC:END -->
