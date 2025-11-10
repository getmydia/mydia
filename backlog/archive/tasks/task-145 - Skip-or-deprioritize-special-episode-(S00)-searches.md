---
id: task-145
title: Skip or deprioritize special episode (S00) searches
status: To Do
assignee: []
created_date: '2025-11-10 18:21'
labels:
  - enhancement
  - configuration
  - usenet
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Special episodes (season 0) are often bonus content, deleted scenes, or extras that are rarely available on indexers. The monitor currently searches for them with the same priority as regular episodes, wasting API quota.

**Current Behavior:**
From logs, we can see special episodes being searched individually:
```
[info] Search completed: query=Bluey S00E27, indexers=2, results=0, time=1929ms
[warning] No results found for episode
[info] Search completed: query=Bluey S00E43, indexers=2, results=0, time=4ms
[warning] No results found for episode
```

These searches almost always fail but consume API quota.

**Impact:**
- Special episodes often have 50+ entries per show
- Success rate is typically very low (<5%)
- Wastes significant API quota on low-priority content

**Proposed Solutions (choose one or combine):**
1. **Skip S00 entirely by default** with opt-in setting
2. **Search S00 only when explicitly requested** by user
3. **Deprioritize S00 searches** (search only after all regular episodes are found)
4. **Reduce S00 search frequency** (only search once per week instead of every monitor run)

**Implementation Notes:**
- Filter out season 0 episodes in `process_episodes_with_smart_logic/3` before searching
- Add configuration option: `monitor_special_episodes` (default: false)
- Could also apply to season 99 or other special season numbers
<!-- SECTION:DESCRIPTION:END -->
