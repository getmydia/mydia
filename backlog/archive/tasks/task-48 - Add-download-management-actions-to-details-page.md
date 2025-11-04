---
id: task-48
title: Add download management actions to details page
status: To Do
assignee: []
created_date: '2025-11-04 21:08'
labels:
  - feature
  - ui
  - downloads
dependencies:
  - task-39
  - task-21
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Implement actions for managing downloads from the media details page.

Add the following actions in the download history table:
- Retry failed downloads
- Cancel active/pending downloads
- Remove completed downloads from history
- View detailed download information (torrent info, peers, speed, etc.)
- Priority adjustment for queued downloads

Currently download history is displayed but has no interactive actions.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 User can retry failed downloads
- [ ] #2 User can cancel active downloads
- [ ] #3 Download details are accessible
- [ ] #4 Actions update the download status appropriately
- [ ] #5 UI reflects changes in real-time via PubSub
<!-- AC:END -->
