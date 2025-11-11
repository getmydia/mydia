---
id: task-167.1
title: 'Phase 1: Replace static lists with flexible regex patterns'
status: To Do
assignee: []
created_date: '2025-11-11 16:45'
labels:
  - enhancement
  - file-parsing
dependencies: []
parent_task_id: task-167
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Replace hardcoded lists (@audio_codecs, @codecs, @sources, etc.) with flexible regex patterns that handle variations automatically.

## Tasks

1. Create regex patterns for:
   - Audio codecs: `(?:DD(?:P)?(?:\d+\.?\d*)?|DTS(?:-HD\.MA|-HD|-X)?|TrueHD|Atmos|AAC|AC3|EAC3)`
   - Video codecs: `(?:[hx]\.?26[45]|HEVC|AVC|XviD|DivX|VP9|AV1|NVENC)`
   - Resolutions: `(?:\d{3,4}p|4K|8K|UHD)`
   - Sources: `(?:REMUX|BluRay|BDRip|BRRip|WEB(?:-DL)?|WEBRip|HDTV|DVDRip)`

2. Update extraction functions to use regex instead of list matching
3. Test with existing test suite (should pass 54/54 tests)
4. Add new test cases for codec variations

## Expected Outcome

- Handles DD5.1, DD51, DDP5.1, DDP51 with single pattern
- No more manual list updates for codec variations
- All existing tests pass

## Effort: 2-4 hours
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 All 54+ existing FileParser tests pass
- [ ] #2 New test cases added for codec variations (DD51, DDP51, EAC3, etc.)
- [ ] #3 Audio/video codec extraction uses regex patterns instead of static lists
- [ ] #4 Code is backward compatible with existing behavior
<!-- AC:END -->
