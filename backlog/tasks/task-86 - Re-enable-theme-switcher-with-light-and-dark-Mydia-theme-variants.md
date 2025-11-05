---
id: task-86
title: Re-enable theme switcher with light and dark Mydia theme variants
status: Done
assignee: []
created_date: '2025-11-05 19:21'
updated_date: '2025-11-05 19:27'
labels:
  - ui
  - theme
  - enhancement
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Implement a light theme variant of the Mydia color scheme and restore the theme switcher functionality that was removed in Task-85.

**Current state:**
- Only "mydia" dark theme exists
- Theme switcher JavaScript was removed from root.html.heex
- Theme is hardcoded to `data-theme="mydia"`
- Theme switcher UI may still exist but is non-functional

**Required implementation:**

1. **Create Mydia Light theme** (`mydia-light`)
   - Invert base colors as per docs/architecture/colors.md "Future Considerations"
   - base-100: Slate-50 (#f8fafc) - main background (light)
   - base-200: Slate-100 (#f1f5f9) - card background
   - base-300: Slate-200 (#e2e8f0) - hover states
   - base-content: Slate-900 (#0f172a) - text (dark on light)
   - Keep same action colors (primary/secondary/accent) with adjusted brightness if needed
   - Maintain semantic colors (success/warning/error/info)
   - Include both HSL variables (DaisyUI) and OKLCH variables (Tailwind v4)

2. **Rename existing theme** from "mydia" to "mydia-dark" for consistency

3. **Restore theme switcher**
   - Implement JavaScript in root.html.heex to switch between themes
   - Support options: "mydia-dark", "mydia-light", and "system" (auto-detect)
   - Persist user preference in localStorage
   - Watch for system theme changes when in "system" mode

4. **Update theme switcher UI** (if it exists, otherwise create it)
   - Add controls to switch between dark/light/system
   - Show current theme state
   - Integrate into navbar or settings

**Design considerations:**
- Light theme should maintain WCAG AA accessibility standards
- Both themes should feel cohesive and part of the Mydia brand
- Transitions between themes should be smooth
- Default to "system" preference to respect user OS settings
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Create mydia-light theme with inverted base colors and both HSL/OKLCH variables
- [x] #2 Rename existing theme to mydia-dark for consistency
- [x] #3 Implement theme switcher JavaScript with dark/light/system options
- [x] #4 Add or update theme switcher UI in the interface
- [x] #5 Theme preference persists in localStorage
- [x] #6 System theme detection works correctly
- [x] #7 Both themes maintain WCAG AA accessibility standards
- [x] #8 Smooth transitions between themes
- [x] #9 All pages render correctly in both light and dark themes
- [x] #10 Document light theme in docs/architecture/colors.md
<!-- AC:END -->
