---
id: task-23.7
title: Implement library scanner background job
status: To Do
assignee: []
created_date: '2025-11-04 03:39'
updated_date: '2025-11-04 03:39'
labels:
  - library
  - oban
  - background-jobs
  - backend
dependencies:
  - task-23.4
  - task-23.5
  - task-23.6
parent_task_id: task-23
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Create an Oban background job that orchestrates the library scanning process: file system scanning → file parsing → metadata matching → database updates. The job should run on a schedule (e.g., daily at 2 AM as shown in technical.md) and can be triggered manually.

The job should be resilient to failures, track progress, and provide status updates. Support full scans and incremental scans (only new/changed files).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Job orchestrates: scan files → parse names → match metadata → update database
- [ ] #2 Scheduled execution runs daily at configurable time
- [ ] #3 Manual trigger is available via API and UI
- [ ] #4 Job tracks progress (files scanned, matched, failed)
- [ ] #5 Incremental scans only process new/changed files since last scan
- [ ] #6 Full scans can be triggered to re-process entire library
- [ ] #7 Job handles failures gracefully and retries with backoff
- [ ] #8 Scan status and results are exposed via API for UI display
- [ ] #9 Concurrent scans are prevented with job locking
- [ ] #10 Job performance scales to libraries with 50,000+ files
<!-- AC:END -->
