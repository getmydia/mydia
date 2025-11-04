---
id: task-43.1
title: Implement manual search from media details page
status: Done
assignee: []
created_date: '2025-11-04 21:11'
updated_date: '2025-11-04 21:20'
labels:
  - feature
  - ui
  - search
  - downloads
dependencies:
  - task-22
parent_task_id: task-43
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Integrate the manual search button with the indexers/search system to trigger searches for specific media items.

- Connect "Manual Search" button to Indexers context
- Trigger search for the specific media item (movie or TV show)
- Display search results in a modal or navigate to search page with pre-filtered results
- Allow user to select and download a release from results
- Handle both movie and TV show searches appropriately
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Manual search button triggers search for the media item
- [ ] #2 Search results are displayed to the user
- [ ] #3 User can initiate downloads from search results
- [ ] #4 Works for both movies and TV shows
<!-- AC:END -->
