---
id: task-144
title: Cache failed episode searches to prevent repeated API calls
status: To Do
assignee: []
created_date: '2025-11-10 18:21'
labels:
  - enhancement
  - performance
  - usenet
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The episode monitor currently has no memory of failed searches, so it will repeatedly search for episodes that don't exist, wasting API quota on every monitor run.

**Current Behavior:**
- When an episode search returns 0 results, it's logged as a warning but not cached
- Next monitor run will search for the same episode again
- This pattern repeats indefinitely for unavailable content

**Example from Logs:**
```
[info] Search completed: query=Bluey S00E27, indexers=2, results=0, time=1929ms
[warning] No results found for episode
```
This same search will be repeated on the next monitor run.

**Impact:**
- Wastes API quota on content that's not available
- Particularly problematic for special episodes (S00) which are often not released
- Slows down monitor runs unnecessarily

**Proposed Solution:**
1. Track failed searches in the database with timestamps
2. Implement cooldown periods (e.g., 24 hours, 7 days, 30 days with exponential backoff)
3. Skip searching for episodes that failed recently
4. Allow manual retry/clearing of failed search cache
5. Different cooldown periods based on episode age (newer episodes retry more frequently)

**Implementation Notes:**
- Could add a `failed_searches` table with columns: episode_id, searched_at, retry_after
- Or add fields to the episodes table: last_search_at, next_retry_at, search_attempts
- Consider cache invalidation strategy when new indexers are added
<!-- SECTION:DESCRIPTION:END -->
