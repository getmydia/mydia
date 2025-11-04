---
id: task-31.3
title: Add manual entry fallback for failed release title parsing
status: To Do
assignee: []
created_date: '2025-11-04 21:23'
labels:
  - ui
  - liveview
  - metadata
  - forms
dependencies: []
parent_task_id: task-31
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
When FileParser cannot parse a release title with sufficient confidence, provide a manual entry form for the user to search metadata themselves.

**Requirements:**
- Detect low confidence or failed parsing
- Show modal/form with pre-filled search fields from parsed data
- Allow user to edit title, year, and media type
- Execute metadata search with user-provided values
- Continue normal add-to-library flow with selected metadata

**UI Flow:**
1. Parse fails or confidence < threshold
2. Show "Could not parse release. Search manually?" modal
3. Form with: title (pre-filled), year (optional), type (movie/tv)
4. Search button executes metadata search
5. Show results (may need disambiguation)
6. Continue to MediaItem creation

**Location:** `lib/mydia_web/live/search_live/index.ex` and new form component
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Shows manual search form when parsing fails
- [ ] #2 Form pre-populated with parsed data when available
- [ ] #3 User can edit search parameters
- [ ] #4 Manual search executes metadata provider search
- [ ] #5 Results feed into normal disambiguation flow
- [ ] #6 Covers AC #9 from parent task
<!-- AC:END -->
