---
id: task-8
title: Set up Oban for background job processing
status: Done
assignee:
  - '@assistant'
created_date: '2025-11-04 01:52'
updated_date: '2025-11-04 03:42'
labels:
  - background-jobs
  - oban
  - automation
dependencies:
  - task-4
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Configure Oban with SQLite-compatible engine for background jobs. Create job modules for library scanning, automated search, download monitoring, and scheduled tasks.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Oban dependency added and configured
- [x] #2 Oban.Engines.Basic set up for SQLite
- [x] #3 Queue configuration (critical, default, media, search, notifications)
- [x] #4 LibraryScanner job created
- [x] #5 DownloadMonitor job created
- [x] #6 Cron plugins configured for scheduled jobs
- [x] #7 Oban migrations run successfully
- [x] #8 Jobs can be enqueued and processed
<!-- AC:END -->
