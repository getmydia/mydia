---
id: task-143
title: Add rate limiting to episode monitor searches
status: To Do
assignee: []
created_date: '2025-11-10 18:21'
labels:
  - bug
  - performance
  - usenet
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The episode monitor currently makes search requests without any delays, which can quickly exhaust usenet indexer API quotas. For example, a single TV show with 3 seasons can trigger 150+ API calls in rapid succession.

**Current Behavior:**
- `lib/mydia/jobs/tv_show_search.ex:588-603` searches all episodes immediately via `Enum.map`
- No delays between individual searches
- All searches happen sequentially without rate limiting

**Impact:**
- Usenet indexers typically have API rate limits (e.g., 100-1000 calls per day)
- Current behavior will exhaust quotas in hours with just a few monitored shows
- May result in temporary bans or degraded service

**Proposed Solution:**
Add configurable rate limiting between search requests:
1. Add delay between individual episode searches (e.g., 1-2 seconds)
2. Add delay between season searches
3. Make the delay configurable via application settings
4. Consider different delays for torrent vs usenet indexers (usenet needs stricter limits)

**Implementation Notes:**
- Could use `Process.sleep/1` between searches in `search_individual_episodes/2`
- Or implement a proper rate limiter module using GenServer
- Should be configurable per-indexer type
<!-- SECTION:DESCRIPTION:END -->
