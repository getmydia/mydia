---
id: task-147
title: Improve season pack fallback logic to be less aggressive
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
When season pack search fails (returns 0 results), the system immediately falls back to searching ALL individual episodes in that season. This is too aggressive and wastes API quota.

**Current Behavior:**
From `lib/mydia/jobs/tv_show_search.ex:482-542` (`search_season/4`):
- Line 501: Search for season pack
- Line 510: If no results, immediately fallback to searching all episodes
- Line 527: If season pack has episode markers, fallback to all episodes

This means a single failed season pack search can trigger 50+ individual episode searches.

**Impact:**
- Season pack search fails → 50+ API calls immediately
- No middle ground between "season pack" and "search everything"
- Particularly wasteful when content isn't available yet

**Proposed Solutions:**

1. **Sample-based approach**: 
   - Search for first 2-3 episodes of the season
   - Only search remaining episodes if samples succeed
   - Saves API calls when entire season isn't available

2. **Delayed fallback**:
   - Don't fallback to individual episodes immediately
   - Wait X hours/days before trying individual episodes
   - Retry season pack search a few times first

3. **Batch fallback**:
   - Search episodes in small batches (e.g., 5 at a time)
   - If first batch fails, skip remaining episodes for this run
   - Continue in next monitor run

4. **Smarter detection**:
   - If show is currently airing, fallback makes sense
   - If show is old/complete, no season pack = likely not available

**Implementation Notes:**
- Modify fallback logic in `search_season/4` around lines 510 and 527
- Add configuration for fallback strategy
- Consider adding a "sample search" function before full fallback
<!-- SECTION:DESCRIPTION:END -->
