---
id: task-22.5
title: 'Implement search aggregation, deduplication, and ranking'
status: Done
assignee: []
created_date: '2025-11-04 03:36'
updated_date: '2025-11-04 14:19'
labels:
  - search
  - indexers
  - backend
  - performance
dependencies:
  - task-22.1
  - task-22.2
parent_task_id: task-22
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Create the search orchestration layer that queries multiple indexers concurrently, aggregates results, removes duplicates, and ranks them by quality and seeders. This provides the unified search experience across all configured indexers.

Use Task.async_stream for concurrent searches with timeout and error handling. Implement smart deduplication based on release name similarity and hash matching. Rank results considering quality profile preferences, seeder count, file size, and release group reputation.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Search queries are sent to all enabled indexers concurrently
- [x] #2 Individual indexer failures don't block results from other sources
- [x] #3 Duplicate results are identified and merged based on hash and name similarity
- [x] #4 Results are ranked by quality tier, seeders, and file size appropriateness
- [x] #5 Search timeout is configurable per indexer with sensible defaults
- [x] #6 Empty results from all indexers return appropriate response
- [x] #7 Search performance metrics are logged (response times, success rates)
- [x] #8 Quality profile preferences influence result ranking
<!-- AC:END -->
