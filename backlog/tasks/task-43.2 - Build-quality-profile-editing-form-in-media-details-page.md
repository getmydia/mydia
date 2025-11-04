---
id: task-43.2
title: Build quality profile editing form in media details page
status: Done
assignee: []
created_date: '2025-11-04 21:11'
updated_date: '2025-11-04 21:20'
labels:
  - feature
  - ui
  - quality-profiles
dependencies:
  - task-32
parent_task_id: task-43
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Build the quality profile editing form in the edit modal on the media details page.

- Create a form to select/change the quality profile
- Load available quality profiles from Settings context
- Allow user to save the updated quality profile
- Show current quality profile selection
- Update the media item with the new quality profile
- Close modal and refresh display after successful save
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Edit modal displays available quality profiles
- [ ] #2 User can select a different quality profile
- [ ] #3 Changes are saved to the database
- [ ] #4 UI reflects the updated quality profile
- [ ] #5 Modal closes after successful save
<!-- AC:END -->
