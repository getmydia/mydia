---
id: task-149.4
title: Cache failed searches with cooldown periods
status: To Do
assignee: []
created_date: '2025-11-10 18:25'
labels:
  - enhancement
  - performance
  - usenet
dependencies: []
parent_task_id: task-149
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Track failed searches to avoid repeatedly searching for unavailable content.

**Current Issue:**
- No memory of failed searches
- Same failed searches repeated every monitor run
- Wastes quota on content that doesn't exist

**Implementation:**
1. Track failed searches in database with timestamps
2. Implement cooldown periods (24h, 7d, 30d with exponential backoff)
3. Skip searching episodes that failed recently
4. Allow manual retry/clearing of cache
5. Different cooldown for episode age (newer = retry more frequently)

**Database Options:**
- New table: `failed_searches` (episode_id, searched_at, retry_after)
- Or add to episodes: `last_search_at`, `next_retry_at`, `search_attempts`

**Cache Invalidation:**
- Reset when new indexers added
- Manual "clear search history" option
<!-- SECTION:DESCRIPTION:END -->
