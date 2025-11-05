---
id: task-84
title: Improve download queue information display clarity
status: Done
assignee: []
created_date: '2025-11-05 19:00'
updated_date: '2025-11-05 19:02'
labels: []
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The download queue currently displays information like:
"BitSearch • 0.0% • — • 3.15 GB • — • 9 seeds"

The dashes are unclear - users don't know what they represent. Based on observations:
- First dash: likely download speed (shown as "—" when not available)
- Second dash: likely ETA/time remaining (shown as "—" when not available, sometimes shows actual time)

The display needs to be more explicit about what each field represents, especially when values are unavailable.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Download queue display clearly labels or formats speed field (e.g., 'Speed: —' or 'No speed data' instead of just '—')
- [x] #2 Download queue display clearly labels or formats ETA field (e.g., 'ETA: —' or 'ETA: 5m' instead of just '—')
- [x] #3 All download information fields are immediately understandable without guessing
- [x] #4 Display remains compact and visually clean while being more informative
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Updated the download queue metadata display in `lib/mydia_web/live/downloads_live/index.html.heex` to add clear labels for the speed and ETA fields.

Changes made:
- Added "Speed:" label before the speed value (line 171)
- Added "ETA:" label before the ETA value (line 175)

This makes the display format much clearer:
- Before: "BitSearch • 0.0% • — • 3.15 GB • — • 9 seeds"
- After: "BitSearch • 0.0% • Speed: — • 3.15 GB • ETA: — • 9 seeds"

The display remains compact and visually clean while being immediately understandable. Users can now clearly see what each field represents, even when values are unavailable (shown as "—").
<!-- SECTION:NOTES:END -->
