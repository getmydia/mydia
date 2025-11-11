---
id: task-171.1
title: Remove redundant Scan Files step from import wizard
status: Done
assignee:
  - assistant
created_date: '2025-11-11 18:38'
updated_date: '2025-11-11 18:50'
labels:
  - ui-ux
  - import-media
  - simplification
dependencies: []
parent_task_id: task-171
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The "Scan Files" step (index.html.heex:111-125) is just a loading screen with no user interaction. It immediately transitions to the matching phase. This creates an unnecessary step in the wizard that doesn't add value.

## Current Flow
1. Select Path
2. Scan Files (loading screen - no-op)
3. Review Matches
4. Import
5. Complete

## Proposed Flow
1. Select Path
2. Review Matches (with loading state during scan/match)
3. Import
4. Complete

## Implementation
- Remove the :scanning step from the wizard
- Combine scanning and matching into a single loading state on the Review Matches screen
- Update the progress steps component to reflect 4 steps instead of 5
- Ensure all event handlers and state transitions work correctly
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Wizard shows 4 steps instead of 5
- [x] #2 Scanning and matching happen as a single loading phase
- [x] #3 User flow feels more streamlined
- [x] #4 No functionality is lost
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Implementation Summary

Successfully removed the redundant "Scan Files" step from the Import Media workflow. The wizard now flows more smoothly with 4 steps instead of 5:

### Changes Made:

1. **Template (index.html.heex)**:
   - Updated progress steps component (lines 23-39) to show 4 steps: Select Path → Review Matches → Import → Complete
   - Removed the separate `:scanning` step section (previously lines 115-129)
   - Combined scanning and matching into a single loading state (lines 112-151) that shows during the Review Matches phase
   - The loading state dynamically shows "Scanning Directory" or "Matching Files" based on the current operation

2. **LiveView Module (index.ex)**:
   - Updated `select_library_path` event handler (line 60) to set `step: :review` instead of `:scanning`
   - Updated `start_scan` event handler (line 79) to set `step: :review` instead of `:scanning`
   - No changes needed to `handle_info` functions as they already handled the flow correctly

### User Experience Impact:

- The wizard now has 4 clear steps instead of a confusing 5-step process
- Users go directly from "Select Path" to "Review Matches" with a loading state
- The loading state shows clear progress: first scanning, then matching
- No functionality was lost - all file scanning, matching, and import logic remains intact
- The flow feels more streamlined and purposeful

### Testing:

- Precommit checks passed successfully
- Code compiles without errors
- Formatter applied consistent styling
<!-- SECTION:NOTES:END -->
