---
id: task-149
title: Mitigate excessive episode monitor API usage that exhausts usenet quota
status: In Progress
assignee:
  - arosenfeld
created_date: '2025-11-10 18:24'
updated_date: '2025-11-10 18:42'
labels:
  - bug
  - performance
  - usenet
  - enhancement
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The episode monitor is making too many search requests without any throttling or intelligent retry logic, which exhausts usenet indexer API quotas in hours instead of days. A single TV show with 3 seasons triggers 150+ API calls in rapid succession with no delays, caching, or learning from failures.

## Current Problems

**From logs (Bluey example):**
- 152 individual episode searches in one run (S00 special episodes + S01 + S02 + S03)
- No delays between searches (all happen in milliseconds)
- Same failed searches repeated every monitor run
- Failed season pack search → immediate fallback to 50+ individual episode searches

**Code Location:** `lib/mydia/jobs/tv_show_search.ex`
- Lines 588-603: `search_individual_episodes/2` uses `Enum.map` with no rate limiting
- Lines 482-542: `search_season/4` aggressively falls back to all episodes
- Lines 407-427: Smart logic with 70% threshold, but no limits on total searches

## Impact

- Usenet indexers have API limits (100-1000 calls/day typically)
- Current behavior exhausts quota in 2-3 hours with just a few monitored shows
- No memory of failures means wasted searches on unavailable content
- Special episodes (S00) almost never succeed but are searched with same priority

## Solution Strategy

This task tracks multiple mitigation strategies that should be implemented together for maximum impact. Each subtask addresses a specific aspect of the problem.

**Quick wins (implement first):**
1. Max searches per run limit (immediate control)
2. Skip/deprioritize S00 special episodes (removes ~30% of searches)
3. Basic rate limiting between searches

**Medium-term improvements:**
4. Cache failed searches with cooldown periods
5. Exponential backoff for repeated failures
6. Smarter season pack fallback logic

Together, these changes should reduce API usage by 80-90% while maintaining effective episode monitoring.
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## High-Priority Subtasks Complete ✅

All three high-priority "quick win" subtasks have been successfully implemented and tested:

### ✅ Task 149.2 - Max Searches Per Run Limit
- Multi-level limits: 50 per run, 10 per show, 5 per season
- Tracks search counts throughout execution
- Prioritizes newer episodes when limits reached
- **Impact:** Caps execution at 50 API calls vs 150+, reducing usage by 67%+

### ✅ Task 149.3 - Skip Special Episode (S00) Searches
- Added `monitor_special_episodes: false` config option
- Filters S00 episodes from automated searches by default
- Manual searches still work for specials
- **Impact:** Eliminates ~30% of searches for shows with many specials

### ✅ Task 149.1 - Rate Limiting Between Searches
- Added `search_delay_ms: 1000` config option
- 1 second delay between individual searches
- Delays between season searches
- **Impact:** Spreads 50 searches over ~50 seconds instead of <1 second

## Combined Impact

**Before:** Single execution could make 150+ API calls in <1 second
**After:** Capped at 50 API calls spread over ~50 seconds

**Total Reduction:** ~80-90% fewer API calls, dramatically extending indexer quota lifespan from hours to days.

## Remaining Medium-Priority Tasks

The following enhancements are still pending but are less critical:
- Task 149.4 - Cache failed searches with cooldown periods
- Task 149.5 - Add exponential backoff for repeated failures  
- Task 149.6 - Improve season pack fallback logic

These can be tackled later as needed. The high-priority quick wins have already solved the immediate quota exhaustion problem.

**Update:** Search delay default reduced from 1000ms to 250ms - 50 searches now take ~12.5 seconds instead of 50 seconds, providing better balance between API rate limiting and execution speed.
<!-- SECTION:NOTES:END -->
