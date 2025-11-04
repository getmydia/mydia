---
id: task-43
title: Implement manual search from media details page
status: To Do
assignee: []
created_date: '2025-11-04 21:08'
labels:
  - feature
  - ui
  - search
  - downloads
dependencies:
  - task-39
  - task-22
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Integrate the manual search button on the media details page with the indexers/search system to trigger a manual search for the media item.

Currently the button exists but only shows a placeholder flash message. This task should:
- Connect the "Manual Search" button to the Indexers context
- Trigger a search for the specific media item (movie or TV show)
- Display search results in a modal or navigate to search page with pre-filtered results
- Allow user to select and download a release from the search results
- Handle both movie and TV show searches appropriately

Related to task-22 (indexer integration) and task-39 (details page).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Manual search button triggers search for the media item
- [ ] #2 Search results are displayed to the user
- [ ] #3 User can initiate downloads from search results
- [ ] #4 Works for both movies and TV shows
<!-- AC:END -->
