---
id: task-43.6
title: Add download management actions to details page
status: In Progress
assignee:
  - assistant
created_date: '2025-11-04 21:11'
updated_date: '2025-11-04 21:24'
labels:
  - feature
  - ui
  - downloads
dependencies:
  - task-21
parent_task_id: task-43
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Implement actions for managing downloads from the media details page.

- Retry failed downloads
- Cancel active/pending downloads
- Remove completed downloads from history
- View detailed download information (torrent info, peers, speed, etc.)
- Priority adjustment for queued downloads
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 User can retry failed downloads
- [ ] #2 User can cancel active downloads
- [ ] #3 Download details are accessible
- [ ] #4 Actions update the download status appropriately
- [ ] #5 UI reflects changes in real-time via PubSub
<!-- AC:END -->
