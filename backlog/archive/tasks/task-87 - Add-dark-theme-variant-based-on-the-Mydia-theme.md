---
id: task-87
title: Add dark theme variant based on the Mydia theme
status: To Do
assignee: []
created_date: '2025-11-05 19:15'
labels:
  - ui
  - theme
  - enhancement
dependencies: []
priority: low
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
After Task-85 implementation, we only have the "mydia" theme which is a dark theme. However, users may want additional dark theme variants for different preferences or use cases.

Current state:
- Single "mydia" theme exists (dark theme with Slate-900 base)
- No alternative dark theme variants available

Options for dark theme variants:
1. **Mydia Dark (Darker)** - An even darker variant with deeper blacks for OLED displays or maximum contrast
   - base-100: Pure black or near-black (#000000 or #0a0a0a)
   - base-200: Very dark gray (#0f0f0f)
   - Keep same accent colors (blue, purple, cyan)

2. **Mydia Dark (Warmer)** - A warmer dark variant with slight brown/amber tones
   - Replace cool slate grays with warm gray-brown bases
   - Slightly adjust accent colors to warmer variants

3. **Mydia Dark (Higher Contrast)** - Increase contrast between elements
   - Lighter text colors (brighter whites)
   - More pronounced differences between base-100/200/300

The original Mydia theme uses Slate colors (cool-toned grays) which are excellent for media viewing. Additional variants would provide user choice while maintaining the Mydia design system.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Decide which dark theme variant(s) to implement
- [ ] #2 Create new theme configuration with variant-specific colors
- [ ] #3 Maintain consistency with Mydia color palette (same primary/secondary/accent colors)
- [ ] #4 Test theme variant renders correctly across all pages
- [ ] #5 Update theme switcher to include new dark variant option
- [ ] #6 Document the new dark theme variant in docs/architecture/colors.md
<!-- AC:END -->
