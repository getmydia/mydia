---
id: task-148
title: Add exponential backoff for repeated search failures
status: To Do
assignee: []
created_date: '2025-11-10 18:21'
labels:
  - enhancement
  - usenet
  - performance
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Episodes that consistently fail to be found should be retried less frequently over time, using exponential backoff to reduce wasted API calls.

**Current Behavior:**
- Every monitor run searches for the same missing episodes
- No consideration of search history or failure patterns
- Content that failed 50 times is searched with same frequency as new content

**Impact:**
- Wastes API quota on content that's likely not available
- No learning from past failures
- Slows down discovery of newly available content

**Proposed Solution:**
Implement exponential backoff based on failure count:

```
Attempt 1: Retry immediately
Attempt 2-3: Retry after 6 hours
Attempt 4-7: Retry after 24 hours  
Attempt 8-15: Retry after 3 days
Attempt 16-30: Retry after 7 days
Attempt 31+: Retry after 30 days
```

Special cases:
- **Recently aired episodes** (< 7 days old): Retry more aggressively
- **Old episodes** (> 6 months): Move to long-term retry faster
- **Manual search requested**: Bypass backoff
- **New indexer added**: Reset backoff for all episodes

**Implementation:**
1. Add fields to episodes table or create separate tracking table:
   - `search_attempt_count` (integer)
   - `last_search_at` (timestamp)
   - `next_retry_at` (timestamp)

2. Create backoff calculation function:
```elixir
defp calculate_next_retry(attempt_count, episode_air_date) do
  # Logic here
end
```

3. Filter episodes before searching:
```elixir
defp get_episodes_eligible_for_search(episodes) do
  now = DateTime.utc_now()
  Enum.filter(episodes, fn ep ->
    is_nil(ep.next_retry_at) or DateTime.compare(ep.next_retry_at, now) == :lt
  end)
end
```

4. Update counters after each search attempt

**Related Tasks:**
- Depends on or overlaps with task about caching failed searches
<!-- SECTION:DESCRIPTION:END -->
