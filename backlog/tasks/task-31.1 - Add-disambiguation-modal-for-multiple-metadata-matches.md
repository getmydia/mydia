---
id: task-31.1
title: Add disambiguation modal for multiple metadata matches
status: To Do
assignee: []
created_date: '2025-11-04 21:23'
labels:
  - ui
  - liveview
  - modal
  - metadata
dependencies: []
parent_task_id: task-31
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
When multiple metadata search results are found, show a modal allowing the user to select the correct match before adding to library.

**Requirements:**
- Display modal with search results when multiple matches found
- Show poster, title, year, and overview for each match
- Allow user to select the correct match or cancel
- Pass selected match to metadata fetch instead of auto-selecting first

**UI Components:**
- DaisyUI modal with card grid or list layout
- Poster thumbnails with fallback image
- Match confidence indicators if available
- Cancel and Select buttons

**Location:** `lib/mydia_web/live/search_live/index.ex` and new template component
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Shows modal when 2+ metadata matches found
- [ ] #2 Displays poster, title, year, overview for each option
- [ ] #3 User can select a match and continue workflow
- [ ] #4 User can cancel to abort add-to-library
- [ ] #5 Selected match is used for metadata fetch
- [ ] #6 Covers AC #3 from parent task
<!-- AC:END -->
