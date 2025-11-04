---
id: task-31.2
title: Add option to download release immediately after adding to library
status: To Do
assignee: []
created_date: '2025-11-04 21:23'
labels:
  - downloads
  - liveview
  - ui
dependencies:
  - task-29
parent_task_id: task-31
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
After successfully adding media to library, give user option to immediately download the selected release.

**Requirements:**
- Add checkbox/toggle to "add to library" flow for "Download immediately"
- Pass download_url and search result info to download initiation
- Integrate with download client functionality (task-29)
- Show download queue status after initiating

**Flow:**
1. User clicks "add to library" on search result
2. Metadata is fetched and MediaItem created
3. If "download immediately" enabled, initiate download
4. Link download to created MediaItem/Episode
5. Show success with download status

**Location:** `lib/mydia_web/live/search_live/index.ex`
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Checkbox/toggle for immediate download in add-to-library flow
- [ ] #2 Download is initiated after MediaItem creation
- [ ] #3 Download is linked to correct MediaItem/Episode
- [ ] #4 User sees confirmation that both add and download succeeded
- [ ] #5 Covers AC #7 from parent task
<!-- AC:END -->
