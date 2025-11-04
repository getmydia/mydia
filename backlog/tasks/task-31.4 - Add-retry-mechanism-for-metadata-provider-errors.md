---
id: task-31.4
title: Add retry mechanism for metadata provider errors
status: To Do
assignee: []
created_date: '2025-11-04 21:23'
labels:
  - metadata
  - error-handling
  - ui
dependencies: []
parent_task_id: task-31
priority: low
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
When metadata provider API fails, give user option to retry instead of just showing an error.

**Requirements:**
- Detect transient vs permanent metadata provider errors
- Show error message with "Retry" button for transient failures
- Maintain search context (parsed release, user selections)
- Re-attempt metadata search/fetch on retry
- Track retry attempts to prevent infinite loops (max 3 retries)

**Error Types:**
- Network timeouts → Retryable
- 5xx server errors → Retryable
- Rate limiting → Show backoff message
- 404 not found → Not retryable
- Invalid API response → Not retryable

**Location:** `lib/mydia_web/live/search_live/index.ex` error handling
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Distinguishes transient from permanent errors
- [ ] #2 Shows Retry button for transient failures
- [ ] #3 Maintains state across retry attempts
- [ ] #4 Limits retry attempts to prevent loops
- [ ] #5 Shows appropriate message for each error type
- [ ] #6 Covers AC #10 from parent task
<!-- AC:END -->
