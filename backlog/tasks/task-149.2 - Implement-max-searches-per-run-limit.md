---
id: task-149.2
title: Implement max searches per run limit
status: Done
assignee:
  - arosenfeld
created_date: '2025-11-10 18:25'
updated_date: '2025-11-10 18:33'
labels:
  - enhancement
  - configuration
  - usenet
dependencies: []
parent_task_id: task-149
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Add configurable limits to cap total API calls per monitor execution.

**Current Issue:**
- No limit on searches per job run
- Single execution can make 150+ API calls

**Implementation:**
Add limits at multiple levels:
- Per-run limit: Max total searches per execution (e.g., 50)
- Per-show limit: Max searches per show per run (e.g., 10)
- Per-season limit: Max searches per season per run (e.g., 5)

**Configuration:**
```elixir
config :mydia, :episode_monitor,
  max_searches_per_run: 50,
  max_searches_per_show: 10,
  max_searches_per_season: 5
```

**Behavior:**
- Track search count throughout execution
- Prioritize newer episodes when limit reached
- Log skipped episodes for next run
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Implementation Complete

**Changes Made:**

1. **Configuration** (config/config.exs:113-121)
   - Added `:episode_monitor` config with three limit levels
   - `max_searches_per_run: 50` - Global limit per execution
   - `max_searches_per_show: 10` - Per-show limit
   - `max_searches_per_season: 5` - Per-season limit

2. **Helper Functions** (tv_show_search.ex:968-995)
   - `get_max_searches_per_run/0`, `get_max_searches_per_show/0`, `get_max_searches_per_season/0`
   - `limit_reached?/2` - Check if limit exceeded
   - `prioritize_episodes/1` - Sort by air_date desc (newest first)

3. **all_monitored Mode Tracking** (tv_show_search.ex:257-329)
   - Refactored from `Enum.each` to `Enum.reduce_while`
   - Tracks global search count across all shows
   - Halts execution when global limit reached
   - Logs searches performed, remaining, and shows skipped

4. **Per-Show Tracking** (tv_show_search.ex:410-479)
   - `process_episodes_with_smart_logic/4` now accepts and returns search count
   - Tracks searches per show, enforces per-show limit
   - Logs when per-show limit reached and seasons skipped

5. **Per-Season Tracking** (tv_show_search.ex:532-603, 652-703)
   - `search_season/5` increments counter for season pack search
   - `search_individual_episodes/3` enforces per-season limit
   - Prioritizes newer episodes (sorted by air_date desc)
   - Logs detailed statistics: successful, failed, skipped

**Testing:**
- All 24 TV show search tests pass
- Code compiles without errors
- Proper logging at all limit enforcement points

**Impact:**
With default limits (50 run, 10 show, 5 season), a single execution is now capped at 50 API calls instead of potentially 150+, reducing quota usage by 67%+.
<!-- SECTION:NOTES:END -->
