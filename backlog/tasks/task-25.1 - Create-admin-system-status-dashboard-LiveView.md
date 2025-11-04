---
id: task-25.1
title: Create admin system status dashboard LiveView
status: Done
assignee: []
created_date: '2025-11-04 03:52'
updated_date: '2025-11-04 04:01'
labels:
  - admin
  - liveview
  - ui
  - observability
dependencies: []
parent_task_id: task-25
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Build a read-only admin dashboard that displays the current system state including: active configuration values with their sources (env var/database/file/default), monitored library paths and their status, configured download clients and connection status, configured indexers and health status, background job queue status, and database information. This gives administrators full visibility into how the system is currently configured and operating.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 AdminStatusLive LiveView created with admin-only access
- [ ] #2 Configuration section shows all active settings with source badges (ENV/DB/FILE/DEFAULT)
- [ ] #3 Library paths section shows monitored directories and scan status
- [ ] #4 Download clients section shows configured clients with connection health
- [ ] #5 Indexers section shows configured providers with health status
- [ ] #6 Background jobs section shows Oban queue status and recent jobs
- [ ] #7 Database section shows SQLite file location, size, and health
- [ ] #8 UI uses DaisyUI components for consistent styling
- [ ] #9 Real-time updates via LiveView for dynamic status information
<!-- AC:END -->
