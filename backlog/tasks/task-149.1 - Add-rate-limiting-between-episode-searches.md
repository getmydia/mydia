---
id: task-149.1
title: Add rate limiting between episode searches
status: Done
assignee:
  - arosenfeld
created_date: '2025-11-10 18:25'
updated_date: '2025-11-10 18:42'
labels:
  - bug
  - performance
  - usenet
dependencies: []
parent_task_id: task-149
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Add configurable delays between search requests to prevent rapid-fire API calls.

**Current Issue:**
- `lib/mydia/jobs/tv_show_search.ex:588-603` uses `Enum.map` with no delays
- All searches happen in milliseconds

**Implementation:**
1. Add delay between individual episode searches (e.g., 1-2 seconds)
2. Add delay between season searches
3. Make delay configurable via application settings
4. Consider different delays for torrent vs usenet indexers

**Options:**
- Simple: `Process.sleep/1` between searches
- Advanced: Proper rate limiter GenServer module
- Per-indexer configuration
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Implementation Complete

**Changes Made:**

1. **Configuration** (config/config.exs:126-128)
   - Added `search_delay_ms: 1000` to episode_monitor config
   - Default 1 second delay between searches for respectful API usage
   - Set to 0 to disable delays (useful for testing)
   - Configurable per environment (test/dev/prod)

2. **Helper Functions** (tv_show_search.ex:1001-1012)
   - `get_search_delay_ms/0` - Reads delay config setting
   - `apply_search_delay/0` - Applies delay if > 0, uses Process.sleep/1

3. **Episode Search Delays** (tv_show_search.ex:691-694)
   - Added delay after each individual episode search
   - Prevents rapid-fire API calls when searching multiple episodes
   - Applied in the reduce loop in `search_individual_episodes/3`

4. **Season Search Delays** (tv_show_search.ex:486-487)
   - Added delay between processing different seasons
   - Applied after each season completes (pack or individual episodes)
   - In `process_episodes_with_smart_logic/4` reduce loop

**Testing:**
- All 24 TV show search tests pass
- Code compiles without errors
- Tests run quickly (delay defaults to 0 in test env)

**Impact:**
With 1 second delay, searching 50 episodes now takes ~50 seconds instead of <1 second. This spreads API calls over time, being respectful to indexer rate limits and preventing rapid quota exhaustion. Combined with max search limits, this provides comprehensive API usage control.

**Update:** Default delay reduced from 1000ms to 250ms for better balance between API rate limiting and execution speed. 50 searches now take ~12.5 seconds instead of 50 seconds.
<!-- SECTION:NOTES:END -->
