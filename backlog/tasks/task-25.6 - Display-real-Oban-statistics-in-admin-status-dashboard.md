---
id: task-25.6
title: Display real Oban statistics in admin status dashboard
status: To Do
assignee: []
created_date: '2025-11-04 15:49'
labels:
  - ui
  - monitoring
  - oban
  - admin
dependencies:
  - task-24
parent_task_id: task-25
priority: low
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Fix the admin status dashboard to show real Oban job statistics instead of hardcoded zeros. Currently at lib/mydia_web/live/admin_status_live/index.ex:131-148, the get_oban_stats/0 function just returns hardcoded values:

```elixir
%{
  running_jobs: 0,
  queued_jobs: 0,
  queues: []
}
```

This is separate from task-24 which created a dedicated jobs monitoring UI at /admin/jobs. The admin status dashboard at /admin/status should show a summary/overview of the Oban system health including counts of running and queued jobs.

The status dashboard should provide a quick glance at system health, while the dedicated jobs UI provides detailed job history and management.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 get_oban_stats/0 queries actual Oban queue states instead of returning zeros
- [ ] #2 Running jobs count reflects jobs currently executing
- [ ] #3 Queued jobs count reflects jobs waiting to execute across all queues
- [ ] #4 Queue list shows each configured queue with its status
- [ ] #5 Stats update in real-time using LiveView
- [ ] #6 Gracefully handles Oban not being available (dev/test environments)
- [ ] #7 Performance is acceptable (stats retrieval is fast, uses caching if needed)
- [ ] #8 UI clearly distinguishes between healthy (jobs processing) and unhealthy (stuck queues) states
<!-- AC:END -->
