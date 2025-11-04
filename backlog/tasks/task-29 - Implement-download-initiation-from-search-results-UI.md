---
id: task-29
title: Implement download initiation from search results UI
status: To Do
assignee: []
created_date: '2025-11-04 16:00'
labels:
  - downloads
  - liveview
  - ui
  - search
dependencies:
  - task-22.8
  - task-21.1
  - task-21.2
  - task-21.4
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Complete the stubbed download functionality in the search LiveView. When a user clicks the download button for a search result, send the torrent to a configured download client and create a Download record to track progress.

This enables the core acquisition workflow: user searches for media → finds a release → downloads it directly. The download can be associated with a media item (if searching from library) or standalone (if from discovery search).

## Implementation Details

The download button handler exists at `lib/mydia_web/live/search_live/index.ex:99-105` with a TODO placeholder. This task implements the actual functionality.

**Download Flow:**
1. User clicks download button on search result
2. If multiple download clients configured, prompt user to select one (or use default/priority)
3. Send magnet link or torrent file URL to selected download client
4. Create Download record with initial status
5. Show success flash message with link to downloads queue
6. Download monitoring job (task-21.4) handles status updates

**Error Handling:**
- Download client unavailable/offline
- Torrent rejected by client
- Invalid magnet link or torrent file
- No download clients configured

**Context Module:**
Use existing `Mydia.Downloads` context and download client adapters from task-21.1/21.2.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Download button in search results sends torrent to download client
- [ ] #2 Creates Download record with pending status and metadata
- [ ] #3 Handles multiple configured download clients (selection or priority)
- [ ] #4 Shows success message with link to downloads queue
- [ ] #5 Handles errors gracefully (client offline, invalid torrent, etc.)
- [ ] #6 Download appears in downloads queue UI immediately
- [ ] #7 Download monitoring job picks up and tracks status
- [ ] #8 Can optionally associate download with media_item_id if known
<!-- AC:END -->
