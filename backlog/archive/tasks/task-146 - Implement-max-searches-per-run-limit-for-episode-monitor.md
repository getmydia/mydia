---
id: task-146
title: Implement max searches per run limit for episode monitor
status: To Do
assignee: []
created_date: '2025-11-10 18:21'
labels:
  - enhancement
  - configuration
  - usenet
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The episode monitor currently searches for ALL missing episodes in a single run, which can be hundreds of API calls. We need a configurable limit to spread searches across multiple runs.

**Current Behavior:**
- `search_individual_episodes/2` in `lib/mydia/jobs/tv_show_search.ex:588-603` uses `Enum.map` to search all episodes
- No limit on number of searches per job run
- A show with 3 seasons can trigger 150+ searches in one execution

**Impact:**
- Single monitor run can exhaust daily API quota
- No way to control or predict API usage
- Makes it difficult to run monitor frequently without hitting limits

**Proposed Solution:**
Add configurable limits at multiple levels:

1. **Per-run limit**: Max total searches per monitor execution (e.g., 50 searches)
2. **Per-show limit**: Max searches per show per run (e.g., 10 searches)
3. **Per-season limit**: Max searches per season per run (e.g., 5 searches)

When limit is reached:
- Stop searching and continue on next run
- Prioritize newer/more popular episodes first
- Log how many episodes were skipped

**Configuration Example:**
```elixir
config :mydia, :episode_monitor,
  max_searches_per_run: 50,
  max_searches_per_show: 10,
  max_searches_per_season: 5
```

**Implementation Notes:**
- Track search count throughout job execution
- Modify `search_individual_episodes/2` to respect limits using `Enum.take/2`
- Consider priority queue: recent episodes > older episodes
- Add metrics/logging for limit enforcement
<!-- SECTION:DESCRIPTION:END -->
