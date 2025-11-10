---
id: task-149.6
title: Improve season pack fallback logic
status: To Do
assignee: []
created_date: '2025-11-10 18:25'
labels:
  - enhancement
  - usenet
  - performance
dependencies: []
parent_task_id: task-149
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Make season pack fallback less aggressive to avoid triggering 50+ searches immediately.

**Current Issue:**
- Failed season pack search → immediate fallback to ALL episodes
- No middle ground between "season pack" and "search everything"
- Lines 510 and 527 in `search_season/4`

**Implementation Options:**

1. **Sample-based**: Search first 2-3 episodes, only continue if they succeed
2. **Delayed fallback**: Wait X hours before trying individual episodes
3. **Batch fallback**: Search 5 episodes at a time across multiple runs
4. **Smarter detection**: Consider if show is airing vs old/complete

**Recommended:**
- Sample first 3 episodes of season
- If all fail, skip remaining episodes for this run
- If at least one succeeds, continue with full search
- Add configuration for fallback strategy
<!-- SECTION:DESCRIPTION:END -->
