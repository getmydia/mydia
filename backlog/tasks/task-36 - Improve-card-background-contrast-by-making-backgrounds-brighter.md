---
id: task-36
title: Improve card background contrast by making backgrounds brighter
status: In Progress
assignee: []
created_date: '2025-11-04 20:02'
updated_date: '2025-11-04 20:14'
labels:
  - ui
  - theme
  - accessibility
  - daisyui
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
While the Catppuccin dark theme (Frappé) implementation in task-34 improved overall contrast, cards and elevated surfaces still have insufficient contrast with the base background. Card backgrounds need to be brighter to create clearer visual separation and improve readability.

This task focuses on adjusting the card component backgrounds and other elevated surfaces to be more distinguishable from the base background while maintaining the Catppuccin aesthetic and overall theme consistency.

## Context
- Current implementation uses Catppuccin Frappé for dark theme
- DaisyUI card components and elevated surfaces lack sufficient contrast
- Need to maintain WCAG AA accessibility standards
- Should preserve the warm, cohesive Catppuccin color palette
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Cards and elevated surfaces have clearly visible boundaries against the base background
- [ ] #2 Contrast between card backgrounds and base background meets WCAG AA standards
- [ ] #3 Card content (text, buttons, inputs) maintains proper contrast ratios
- [ ] #4 Changes are consistent across all card components (card, modal-box, dropdown, etc.)
- [ ] #5 Theme changes preserve Catppuccin color palette aesthetic
- [ ] #6 Light theme cards are reviewed to ensure no negative impact
- [ ] #7 Interactive states (hover, focus) remain visually distinct
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
## Implementation Plan

### Problem Analysis
The project uses the Catppuccin DaisyUI plugin with `--depth: '1'`, which provides minimal elevation contrast. This causes cards (using `bg-base-100`) to have insufficient visual separation from the base background.

### Solution
Increase the `--depth` value in both Catppuccin theme configurations to enhance contrast between elevation levels (`base-100`, `base-200`, `base-300`).

Change `--depth` from '1' to '3' in both:
- `assets/css/catppuccinTheme.frappe.ts` (dark theme)
- `assets/css/catppuccinTheme.latte.ts` (light theme)

### Implementation Steps
1. Update both theme configuration files
2. Test changes across all pages (Media, Downloads, Admin Status, etc.) in both themes
3. Verify nested elevated surfaces maintain proper hierarchy
4. Check interactive states (hover, focus) remain distinct
5. Verify WCAG AA contrast ratios
6. Ensure changes work well in both light and dark themes

### Files Modified
- `assets/css/catppuccinTheme.frappe.ts`
- `assets/css/catppuccinTheme.latte.ts`
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Implementation Completed

Updated both Catppuccin theme configurations:
- `assets/css/catppuccinTheme.frappe.ts` (dark theme)
- `assets/css/catppuccinTheme.latte.ts` (light theme)

Changed `--depth` parameter from '1' to '3' in both themes to increase contrast between elevation levels.

This affects:
- `base-100` (cards) - brighter and more distinguishable from page background
- `base-200` (nested elevated surfaces) - better contrast against cards
- `base-300` (deeply nested elements) - proper visual hierarchy

**Next Steps:**
- User should test the changes by running the dev server
- Verify card visibility across all pages (Media, Downloads, Admin Status, etc.)
- Check interactive states and nested surfaces
- Verify text contrast and WCAG AA compliance

## Asset Build Required

The TypeScript theme files needed to be compiled by Tailwind CSS. Ran `mix assets.build` to rebuild the assets and pick up the depth parameter changes.

Tailwind successfully compiled the updated theme plugins in 108ms.

User should refresh the browser (hard refresh with Ctrl+Shift+R or Cmd+Shift+R) to see the improved card contrast.

## Root Cause Identified

The `--depth` parameter in the Catppuccin DaisyUI plugin only affects shadows and depth-based visual effects - it does NOT change the actual background colors. The base colors (#303446, #292c3c, #232634) are fixed values from the Catppuccin palette.

The real issue was that the page body had no background color set, causing cards (bg-base-100) to lack visual contrast.

## Solution Applied

Added explicit background color to html and body elements:
```css
html, body {
  background-color: var(--color-base-200);
  color: var(--color-base-content);
}
```

This sets the page background to base-200 (darker) so cards with base-100 (lighter) have proper elevation contrast.

Rebuilt assets successfully. User should hard refresh browser (Ctrl+Shift+R / Cmd+Shift+R) to see the changes.

## Card Background Classes Fixed

Corrected all card components to use `bg-base-100` instead of `bg-base-200`:
- downloads_live/index.html.heex (2 cards)
- media_live/index.html.heex (1 card)
- search_live/index.html.heex (3 cards)
- add_media_live/index.html.heex (1 card)
- page_html/home.html.heex (4 cards)
- jobs_live/index.html.heex (1 card)

**Total: 12 cards fixed**

With body background set to `base-200` and cards using `base-100`, there is now proper elevation contrast throughout the application.

## Layout Contrast Fixed

Adjusted background colors in the layout to create proper visual hierarchy:
- Body/page background: `bg-base-200` (middle tone)
- Sidebar: Changed from `bg-base-200` to `bg-base-300` (darker/recessed)
- Mobile header: Changed from `bg-base-200` to `bg-base-300` (darker/recessed)
- Cards: `bg-base-100` (lighter/elevated)

This creates a proper elevation system where:
- Recessed elements (sidebar, header) use base-300 (darkest)
- Page background uses base-200 (middle)
- Elevated elements (cards) use base-100 (lightest)

## Fixed Additional Elements with Wrong Background

Corrected nested elements inside cards to use `bg-base-300` (darker than card background):
- admin_status_live/index.html.heex: collapse, stats, code block (4 fixes)
- jobs_live/index.html.heex: code blocks and info blocks (3 fixes)
- admin_config_live/index.html.heex: setting items (1 fix)
- search_live/index.html.heex: results table changed to bg-base-100 (1 fix)
- add_media_live/index.html.heex: toolbar changed to bg-base-100 (1 fix)

**Total additional fixes: 10 elements**

All background colors now follow proper elevation hierarchy.
<!-- SECTION:NOTES:END -->
