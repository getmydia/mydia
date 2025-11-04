---
id: task-44
title: Implement quality profile editing in media details page
status: To Do
assignee: []
created_date: '2025-11-04 21:08'
labels:
  - feature
  - ui
  - quality-profiles
dependencies:
  - task-39
  - task-32
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Build the quality profile editing form in the edit modal on the media details page.

Currently a placeholder modal exists. This task should:
- Create a form to select/change the quality profile for a media item
- Load available quality profiles from Settings context
- Allow user to save the updated quality profile
- Show current quality profile selection
- Update the media item with the new quality profile
- Close modal and refresh display after successful save

This completes AC #6 from task-39.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Edit modal displays available quality profiles
- [ ] #2 User can select a different quality profile
- [ ] #3 Changes are saved to the database
- [ ] #4 UI reflects the updated quality profile
- [ ] #5 Modal closes after successful save
<!-- AC:END -->
