---
id: task-149.5
title: Add exponential backoff for repeated failures
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
Retry failed searches less frequently over time using exponential backoff.

**Current Issue:**
- Content that failed 50 times searched with same frequency as new content
- No learning from failure patterns

**Implementation:**
Backoff schedule based on failure count:
- Attempt 1: Retry immediately
- Attempt 2-3: Retry after 6 hours
- Attempt 4-7: Retry after 24 hours
- Attempt 8-15: Retry after 3 days
- Attempt 16-30: Retry after 7 days
- Attempt 31+: Retry after 30 days

**Special Cases:**
- Recently aired (<7 days): Retry more aggressively
- Old episodes (>6 months): Move to long-term retry faster
- Manual search: Bypass backoff
- New indexer: Reset backoff for all episodes

**Database Fields:**
- `search_attempt_count` (integer)
- `last_search_at` (timestamp)
- `next_retry_at` (timestamp)
<!-- SECTION:DESCRIPTION:END -->
