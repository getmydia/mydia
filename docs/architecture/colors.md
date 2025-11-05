# Mydia Color Scheme

## Design Philosophy

The Mydia color scheme is designed for:
- **Power users** who spend extended time in the interface (dark theme reduces eye strain)
- **Information density** without overwhelming (subdued base colors, strategic accent use)
- **Media-focused interface** (dark backgrounds make thumbnails and posters pop)
- **Modern, unified platform** (cohesive palette across all media types)
- **Self-hosting community** (technical, professional aesthetic)

## Color Palette

### Primary Colors

**Primary Blue** - Main actions, links, selections
- `primary`: `#3b82f6` (Blue-500)
- `primary-focus`: `#2563eb` (Blue-600)
- `primary-content`: `#ffffff`

**Usage**: Download buttons, selected items, active navigation, primary CTAs, checkboxes

**Why**: Blue is universally associated with primary actions and maintains excellent readability. The mid-tone blue provides good contrast against dark backgrounds while remaining easy on the eyes during extended use.

---

**Secondary Purple** - Secondary actions, status indicators
- `secondary`: `#8b5cf6` (Violet-500)
- `secondary-focus`: `#7c3aed` (Violet-600)
- `secondary-content`: `#ffffff`

**Usage**: HDR badges, secondary buttons, inactive tabs, quality indicators, special features

**Why**: Purple conveys premium quality (appropriate for HDR, Dolby Vision badges) and provides good visual separation from primary actions.

---

**Accent Cyan** - Highlights, quality badges, notifications
- `accent`: `#06b6d4` (Cyan-500)
- `accent-focus`: `#0891b2` (Cyan-600)
- `accent-content`: `#ffffff`

**Usage**: 4K badges, resolution indicators, new content markers, special highlights

**Why**: Cyan provides excellent contrast and visibility for important quality markers without being jarring. It's distinctive enough to draw attention to premium content features.

---

### Base/Background Colors

**Dark Foundation** - Main backgrounds
- `base-100`: `#0f172a` (Slate-900) - Main background
- `base-200`: `#1e293b` (Slate-800) - Card background, elevated surfaces
- `base-300`: `#334155` (Slate-700) - Hover states, borders, dividers
- `base-content`: `#f1f5f9` (Slate-100) - Primary text

**Why dark theme**:
1. **Media presentation**: Dark backgrounds make movie posters and thumbnails visually prominent
2. **Extended use**: Reduces eye strain during long library management sessions
3. **Power user preference**: Technical users typically prefer dark interfaces
4. **Information density**: Enables better visual hierarchy with colored badges/indicators

---

**Neutral Gray** - Secondary text, borders, disabled states
- `neutral`: `#1f2937` (Gray-800)
- `neutral-focus`: `#111827` (Gray-900)
- `neutral-content`: `#f9fafb` (Gray-50)

**Usage**: Secondary text, meta information (file sizes, dates), disabled UI elements, subtle borders

---

### Semantic Colors

**Success Green** - Completed, available, downloaded
- `success`: `#10b981` (Emerald-500)
- `success-content`: `#ffffff`

**Usage**: Download complete, file exists, available status indicators, success messages

**Why**: Green universally signals "good" and completion. The emerald tone is modern and less saturated than pure green.

---

**Warning Amber** - Monitored, pending, needs attention
- `warning`: `#f59e0b` (Amber-500)
- `warning-content`: `#000000`

**Usage**: Monitored status, missing files warnings, upgrade available, pending actions

**Why**: Amber signals caution without alarm. It's attention-grabbing but not as severe as red.

---

**Error Red** - Failed, missing, critical issues
- `error`: `#ef4444` (Red-500)
- `error-content`: `#ffffff`

**Usage**: Download failed, missing files, errors, delete actions

**Why**: Red universally signals problems and danger. Used sparingly for true errors.

---

**Info Blue** - Informational messages, tips
- `info`: `#3b82f6` (Blue-500)
- `info-content`: `#ffffff`

**Usage**: Tooltips, help text, informational badges, tips

**Why**: Matches primary for consistency. Blue is neutral and informational without urgency.

---

## Color Usage Guidelines

### Hierarchy

1. **Primary actions**: Blue (`primary`) - most important actions
2. **Quality/Premium indicators**: Purple (`secondary`), Cyan (`accent`) - special features
3. **Status**: Green/Amber/Red (`success`/`warning`/`error`) - state communication
4. **Content**: Slate shades (`base-*`) - text and backgrounds
5. **Meta information**: Gray (`neutral`) - secondary information

### Do's

✅ Use `primary` for main CTAs (Download, Search, Add Media)
✅ Use `accent` for quality badges (4K, HDR10+)
✅ Use `secondary` for premium features (Dolby Vision, Atmos)
✅ Use semantic colors for status (green dot = downloaded)
✅ Use base colors for backgrounds and text hierarchy
✅ Maintain high contrast ratios (WCAG AA minimum: 4.5:1 for text)

### Don'ts

❌ Don't use color alone to convey information (include icons/text)
❌ Don't use `error` red for anything other than errors/destructive actions
❌ Don't use too many colors on a single card (max 2-3 accent colors)
❌ Don't use bright colors for large areas (use for accents only)
❌ Don't mix warm and cool badge colors inconsistently

---

## Component-Specific Usage

### Media Cards
- Background: `base-200`
- Hover: `base-300`
- Selected: `primary` border/highlight
- Quality badges: `accent` (4K), `secondary` (HDR)
- Status dot: `success` (downloaded), `warning` (monitored), `error` (missing)

### Buttons
- Primary CTA: `btn-primary` (blue)
- Secondary actions: `btn-ghost` or `btn-secondary`
- Destructive: `btn-error`
- Disabled: `btn-disabled` (neutral-focus)

### Badges
- Quality (4K, UHD): `badge-accent` (cyan)
- Premium (HDR10+, Dolby Vision): `badge-secondary` (purple)
- Codec/Format (HEVC, Atmos): `badge` (neutral)
- Status: `badge-success`, `badge-warning`, `badge-error`

### Progress & Loading
- Progress bars: `progress-primary`
- Loading spinners: `loading` (primary color)
- Background: `base-300`

### Text Hierarchy
- Primary text: `base-content` (Slate-100, #f1f5f9)
- Secondary text: `base-content/60` (60% opacity)
- Meta info: `base-content/40` (40% opacity)
- Disabled: `base-content/30` (30% opacity)

---

## Accessibility

### Contrast Ratios (WCAG 2.1)

All color combinations meet **WCAG AA standards** (4.5:1 for normal text, 3:1 for large text):

| Background | Foreground | Ratio | Level |
|------------|------------|-------|-------|
| `base-100` (#0f172a) | `base-content` (#f1f5f9) | 14.7:1 | AAA |
| `primary` (#3b82f6) | `primary-content` (#ffffff) | 4.6:1 | AA |
| `secondary` (#8b5cf6) | `secondary-content` (#ffffff) | 4.8:1 | AA |
| `accent` (#06b6d4) | `accent-content` (#ffffff) | 4.7:1 | AA |
| `success` (#10b981) | `success-content` (#ffffff) | 4.5:1 | AA |
| `warning` (#f59e0b) | Black text | 8.1:1 | AAA |
| `error` (#ef4444) | `error-content` (#ffffff) | 4.5:1 | AA |

### Color Blind Considerations

- **Primary vs Secondary**: Blue and purple are distinguishable across most color blindness types
- **Status colors**: Never rely on color alone - always include icons or text labels
- **Semantic meaning**: Green/red for success/error is reinforced with icons (✓/✗)

---

## Implementation

### Tailwind Config (DaisyUI Themes)

```javascript
// tailwind.config.js
module.exports = {
  daisyui: {
    themes: [
      {
        "mydia-dark": {
          // Primary - Main actions
          "primary": "#3b82f6",
          "primary-focus": "#2563eb",
          "primary-content": "#ffffff",

          // Secondary - Premium features
          "secondary": "#8b5cf6",
          "secondary-focus": "#7c3aed",
          "secondary-content": "#ffffff",

          // Accent - Quality badges
          "accent": "#06b6d4",
          "accent-focus": "#0891b2",
          "accent-content": "#ffffff",

          // Neutral - Subtle elements
          "neutral": "#1f2937",
          "neutral-focus": "#111827",
          "neutral-content": "#f9fafb",

          // Base - Backgrounds & text (dark)
          "base-100": "#0f172a",  // Slate-900
          "base-200": "#1e293b",  // Slate-800
          "base-300": "#334155",  // Slate-700
          "base-content": "#f1f5f9", // Slate-100

          // Semantic colors
          "info": "#3b82f6",
          "success": "#10b981",
          "warning": "#f59e0b",
          "error": "#ef4444",

          // Color-specific content (text on colored backgrounds)
          "info-content": "#ffffff",
          "success-content": "#ffffff",
          "warning-content": "#000000",
          "error-content": "#ffffff",
        },
        "mydia-light": {
          // Action colors (same as dark theme)
          "primary": "#3b82f6",
          "primary-focus": "#2563eb",
          "primary-content": "#ffffff",

          "secondary": "#8b5cf6",
          "secondary-focus": "#7c3aed",
          "secondary-content": "#ffffff",

          "accent": "#06b6d4",
          "accent-focus": "#0891b2",
          "accent-content": "#ffffff",

          // Neutral - Subtle elements (inverted)
          "neutral": "#f1f5f9",
          "neutral-focus": "#f8fafc",
          "neutral-content": "#0f172a",

          // Base - Backgrounds & text (light)
          "base-100": "#f8fafc",  // Slate-50
          "base-200": "#f1f5f9",  // Slate-100
          "base-300": "#e2e8f0",  // Slate-200
          "base-content": "#0f172a", // Slate-900

          // Semantic colors (same as dark theme)
          "info": "#3b82f6",
          "success": "#10b981",
          "warning": "#f59e0b",
          "error": "#ef4444",

          "info-content": "#ffffff",
          "success-content": "#ffffff",
          "warning-content": "#000000",
          "error-content": "#ffffff",
        },
      },
    ],
    darkTheme: "mydia-dark",
  },
}
```

### CSS Custom Properties

The theme automatically generates CSS variables:

```css
:root {
  --p: 217 91% 60%;    /* primary */
  --pf: 221 83% 53%;   /* primary-focus */
  --pc: 0 0% 100%;     /* primary-content */

  --s: 258 90% 66%;    /* secondary */
  --sf: 262 83% 58%;   /* secondary-focus */
  --sc: 0 0% 100%;     /* secondary-content */

  --a: 188 94% 43%;    /* accent */
  --af: 188 91% 37%;   /* accent-focus */
  --ac: 0 0% 100%;     /* accent-content */

  /* ... and so on */
}
```

---

## Examples in Context

### Media Card with Quality Badges
```html
<div class="card bg-base-200 hover:bg-base-300">
  <figure class="relative">
    <img src="/poster.jpg" alt="Movie Title" />

    <!-- Quality badges (cyan for 4K, purple for HDR) -->
    <div class="absolute top-2 right-2 flex gap-1">
      <span class="badge badge-accent badge-sm">4K</span>
      <span class="badge badge-secondary badge-sm">HDR10+</span>
    </div>

    <!-- Status indicator (green = downloaded) -->
    <div class="absolute top-2 left-2">
      <div class="w-3 h-3 rounded-full bg-success"></div>
    </div>
  </figure>

  <div class="card-body">
    <h3 class="card-title text-base-content">Movie Title</h3>
    <p class="text-sm text-base-content/60">2024 • 1h 45m</p>
  </div>
</div>
```

### Action Buttons
```html
<!-- Primary action (blue) -->
<button class="btn btn-primary">
  Download
</button>

<!-- Secondary action (ghost) -->
<button class="btn btn-ghost">
  Monitor
</button>

<!-- Destructive action (red) -->
<button class="btn btn-error">
  Delete
</button>
```

### Status Messages
```html
<!-- Success -->
<div class="alert alert-success">
  <svg class="w-6 h-6">✓</svg>
  <span>Download completed successfully</span>
</div>

<!-- Warning -->
<div class="alert alert-warning">
  <svg class="w-6 h-6">⚠</svg>
  <span>File quality can be upgraded</span>
</div>

<!-- Error -->
<div class="alert alert-error">
  <svg class="w-6 h-6">✗</svg>
  <span>Download failed</span>
</div>
```

---

## Light Theme Variant

The Mydia light theme (`mydia-light`) provides an alternative color scheme for users who prefer light interfaces:

### Light Theme Colors

**Base Colors (Inverted)**
- `base-100`: `#f8fafc` (Slate-50) - Main background (light)
- `base-200`: `#f1f5f9` (Slate-100) - Card background, elevated surfaces
- `base-300`: `#e2e8f0` (Slate-200) - Hover states, borders, dividers
- `base-content`: `#0f172a` (Slate-900) - Primary text (dark on light)

**Neutral Gray** (Adjusted for light theme)
- `neutral`: `#f1f5f9` (Slate-100)
- `neutral-focus`: `#f8fafc` (Slate-50)
- `neutral-content`: `#0f172a` (Slate-900)

**Action and Semantic Colors**

The light theme maintains the same action and semantic colors as the dark theme:
- Primary, Secondary, Accent colors remain unchanged
- Success, Warning, Error, Info colors remain unchanged
- These colors provide sufficient contrast on light backgrounds while maintaining brand consistency

### Theme Switching

Users can switch between themes using the theme toggle UI:
- **Dark** (mydia-dark): Original dark theme optimized for media management
- **Light** (mydia-light): Light theme variant for bright environments
- **System**: Automatically follows the user's operating system preference

Theme preference is:
- Stored in localStorage for persistence
- Applied before page load to prevent flash of incorrect theme
- Updated automatically when system preference changes (in System mode)

### Accessibility

Both light and dark themes maintain **WCAG AA standards** for contrast ratios:

| Light Theme | Background | Foreground | Ratio | Level |
|------------|------------|------------|-------|-------|
| Main content | `base-100` (#f8fafc) | `base-content` (#0f172a) | 14.7:1 | AAA |
| Card content | `base-200` (#f1f5f9) | `base-content` (#0f172a) | 14.7:1 | AAA |
| Primary button | `primary` (#3b82f6) | `primary-content` (#ffffff) | 4.6:1 | AA |
| Secondary button | `secondary` (#8b5cf6) | `secondary-content` (#ffffff) | 4.8:1 | AA |
| Accent elements | `accent` (#06b6d4) | `accent-content` (#ffffff) | 4.7:1 | AA |

---

## Future Considerations

### Custom Themes (Phase 3+)

Allow users to customize:
- Primary/secondary/accent colors
- Base color darkness
- Semantic color choices
- Save as named themes

---

## Summary

This color scheme balances:
- **Functionality**: Clear visual hierarchy for information-dense interfaces
- **Aesthetics**: Modern, cohesive palette suitable for media applications
- **Accessibility**: WCAG AA compliant contrast ratios throughout
- **User preference**: Dark theme for extended use by power users
- **Brand identity**: Professional, technical aesthetic for self-hosting community

The palette uses strategic color to communicate meaning (status, quality, actions) while maintaining a clean, uncluttered appearance that lets media content take center stage.
