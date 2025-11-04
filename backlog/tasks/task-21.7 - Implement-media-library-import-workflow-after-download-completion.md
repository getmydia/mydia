---
id: task-21.7
title: Implement media library import workflow after download completion
status: Done
assignee: []
created_date: '2025-11-04 15:49'
updated_date: '2025-11-04 16:37'
labels:
  - downloads
  - library
  - import
  - backend
  - oban
dependencies:
  - task-21.4
  - task-23.4
parent_task_id: task-21
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Complete the media library import workflow that is currently stubbed in the download monitor job. When a download completes, the system should automatically move/copy the files to the appropriate library path, associate them with the correct media item, and trigger metadata updates.

This is the TODO at lib/mydia/jobs/download_monitor.ex:187-192 that says "TODO: Trigger media library import workflow". Currently downloads complete successfully but the files are not imported into the library - they remain in the download client's save path.

The import workflow should:
- Move or copy completed files from download path to library path
- Organize files according to library structure (e.g., TV Shows/ShowName/Season XX/)
- Update media_files table with file locations
- Associate files with correct media_items and episodes
- Trigger metadata refresh if needed
- Handle conflicts (file already exists, wrong media type, etc.)
- Clean up download client after successful import (optional based on config)
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Completed downloads trigger automatic import workflow
- [ ] #2 Files are moved/copied from download path to configured library path
- [ ] #3 Files are organized according to media type structure (Movies/Title/ or TV/Show/Season XX/)
- [ ] #4 media_files table records are created with correct paths and metadata
- [ ] #5 Files are associated with correct media_items and episodes in database
- [ ] #6 Import handles conflicts gracefully (duplicate files, mismatches, permission errors)
- [ ] #7 Download client is optionally cleaned up after successful import (configurable)
- [ ] #8 Import failures are logged with actionable error messages
- [ ] #9 Import progress is tracked and visible in UI
- [ ] #10 Integration tests verify end-to-end flow: download → complete → import → library
<!-- AC:END -->
