---
id: task-85
title: Update DaisyUI theme with new Mydia color scheme
status: Done
assignee: []
created_date: '2025-11-05 19:08'
updated_date: '2025-11-05 19:20'
labels:
  - ui
  - design
  - accessibility
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Replace the current DaisyUI theme configuration with the new Mydia color scheme documented in docs/architecture/colors.md.

The new color scheme includes:
- Enhanced focus states for primary, secondary, and accent colors
- Complete semantic color content values (info-content, success-content, warning-content, error-content)
- Neutral-focus color for better disabled states
- Removal of default "light" and "dark" themes (we only use the custom "mydia" theme)

Current file to update: assets/tailwind.config.js or wherever the DaisyUI theme is configured.

This color scheme is optimized for:
- Power users managing large media libraries
- Dark theme that reduces eye strain
- Strategic use of color for visual hierarchy
- WCAG AA accessibility compliance
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 DaisyUI theme configuration matches the color scheme in docs/architecture/colors.md
- [x] #2 All color values include both base and focus variants where applicable
- [x] #3 All semantic colors include corresponding content colors
- [x] #4 Light and dark default themes are removed (only custom mydia theme remains)
- [x] #5 Application renders with new color scheme across all pages
- [x] #6 No visual regressions in existing UI components
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Fix Applied: OKLCH Color Variables

Discovered that Tailwind v4 uses OKLCH color format for its utility classes (like `bg-base-200`), while DaisyUI uses HSL format for its component variables. The initial implementation only included DaisyUI HSL variables, which caused the theme to appear light because Tailwind utilities were falling back to the default `:where(:root)` light theme.

**Solution:** Updated `mydiaTheme.ts` to include both:
- DaisyUI HSL variables (`--b1`, `--b2`, etc.) for DaisyUI components
- Tailwind v4 OKLCH variables (`--color-base-100`, `--color-primary`, etc.) for Tailwind utility classes
- Added `color-scheme: dark` to properly signal dark theme to browsers

**Color conversions:**
- #0f172a (Slate-900) → oklch(25.33% 0.016 252.42)
- #1e293b (Slate-800) → oklch(31.07% 0.018 251.76)
- #334155 (Slate-700) → oklch(40.47% 0.020 251.43)
- #f1f5f9 (Slate-100) → oklch(95.76% 0.006 252.37)

The theme now correctly displays as dark across all pages.
<!-- SECTION:NOTES:END -->
