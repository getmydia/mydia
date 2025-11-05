---
id: task-86
title: Fix dark theme switcher broken after Mydia theme implementation
status: To Do
assignee: []
created_date: '2025-11-05 19:14'
labels:
  - ui
  - theme
  - bug
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The theme switcher UI is broken after implementing the single Mydia theme in Task-85. The theme switching logic in root.html.heex was removed and replaced with a hardcoded `data-theme="mydia"` attribute.

Current state:
- Theme switcher UI may still exist in the interface but is non-functional
- Only the "mydia" dark theme is available
- Theme switcher JavaScript was removed from root.html.heex

Options to fix:
1. Remove theme switcher UI entirely (if we only want dark theme)
2. Implement a light variant of the Mydia theme and restore theme switching
3. Keep dark-only but add a visual indication that theme switching is disabled

The Mydia theme was designed as a dark theme optimized for media viewing and power users. If a light theme is needed, it should maintain the same color palette but with inverted base colors (as documented in docs/architecture/colors.md under "Future Considerations").
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Decide whether to support theme switching or remove the UI
- [ ] #2 If removing: Remove all theme switcher UI elements from the interface
- [ ] #3 If keeping: Implement light variant of Mydia theme with inverted base colors
- [ ] #4 If keeping: Restore theme switching JavaScript with proper mydia/mydia-light theme names
- [ ] #5 Theme switcher state is consistent with available themes
- [ ] #6 No broken UI elements related to theme switching
<!-- AC:END -->
