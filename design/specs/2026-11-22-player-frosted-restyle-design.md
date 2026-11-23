# Player: Frosted mode restyle

Date: 2026-11-22
Status: draft, awaiting review

## Goal

Frosted mode (`GlassMaterial.frosted`) is the player's look everywhere except
native iOS and macOS, and the only look on Android TV. Today it is stock
Material 3: ink ripples, 52×32 switches, radio dialogs, underlined dropdowns,
`AlertDialog` with end-aligned text buttons. Make it read as a current,
cinematic app: quiet neutral chrome, hairline edges, stepped surfaces, transform
feedback, with the artwork carrying the colour.

Background: `design/research/2026-11-22-modern-media-app-ui.md` (what reads as
modern in late 2026 and why). The visual reference is the mockup canvas made
alongside it; this spec is the source of truth where they differ.

## Success criteria

- No ink ripple or splash anywhere in Frosted mode.
- Dialogs, sheets, menus, selects, switches, checkboxes, chips, buttons and
  toasts match the "Proposed" column of the mockup and the numbers below.
- Television behaviour is unchanged: the same focus stops, the same traversal
  order, the same number of presses for every task. Existing tests of focus
  stops, traversal order and semantics pass without edits to their
  expectations; only tests pinning a visual value this spec changes (such as
  `FocusEmphasis.scale` 1.07) are updated.
- Liquid Glass renders exactly as before (`./dev player glass-diff` shows no
  change).

## Decisions

- **Fill in the existing seams.** `GlassDialog` (27 call sites) and
  `showGlassSheet` (17) already sit in front of every dialog and sheet; today
  their Frosted branch is plain `AlertDialog` / `showModalBottomSheet`. That
  branch gets a designed layout. No parallel `Frosted*` widget family, and no
  third-party kit (forui, shadcn_ui): both are pre-1.0 and neither handles a
  D-pad.
- **Theme first.** Everything `ThemeData` can express goes in
  `AppTheme.build`, so the ~90 files that use Material widgets directly change
  without being touched.
- **Three new house widgets only:** `PressScale`, `AppSegmented`, `AppSelect`.
- **Warm the Projection Booth greys** in the same change (below). Other presets
  keep their colours; they pick up the component changes.
- **Pin `material_ui` exactly.** It went from 1.0 to 1.11.1 in three months and
  Material 3 Expressive is landing there; a caret range would change the stock
  widgets under us.
- **Liquid Glass is out of scope.** Every change is gated on
  `GlassStyle.of(context) == false` or lives on the Frosted branch of
  `AppTheme.build(liquid: false)`. `LiquidGeometry` and the shader are not
  touched.

## Tokens: `SurfaceRoles`

A new `ThemeExtension<SurfaceRoles>` in
`player/lib/core/theme/surface_roles.dart`, built from the `MydiaPalette` in
`AppTheme.build`, so every preset gets one. Read with `context.surfaceRoles`.

| Field | Value | Use |
| --- | --- | --- |
| `hairline` | white 8% | resting edge of cards, menus, sheets, dialogs, chips, inputs |
| `hairlineStrong` | white 14% | interactive edge: secondary buttons, segmented track, select |
| `rim` | white 6%, 1px inset at top | optional top highlight on raised surfaces |
| `hoverOverlay` | white 4% | hover on any control |
| `pressOverlay` | black 12% | press dim on any control |
| `scrim` | `#060607` at 62% | behind dialogs |
| `radiusControl` | 10 | buttons, inputs, select, segmented track (the checkbox uses 5) |
| `radiusMenu` | 14 | menus, popovers, cards in settings |
| `radiusModal` | 20 | dialogs, sheets |

The existing `AppTheme.radius*` constants stay for posters, heroes, rails and
badges (`radiusHeroPoster`, `radiusRail`, `radiusBottomBar`, `radiusBadge`,
`radiusChip`). On the Frosted path `radiusButton`, `radiusCard`, `radiusInput`
and `radiusSheet` are replaced at their theme uses by the ladder above; the
constants themselves stay because Liquid and non-theme code read them.
Nested corners are concentric: inner radius = outer radius minus padding.

## Palette: warmer Projection Booth

Each step keeps its OKLCH lightness; hue moves from about 286° (blue) to 75°
(warm) and chroma drops to 0.003. Accent, text and semantic colours do not
change. `oledBlack`, `slate`, `macos` and `linux` do not change.

| Field | Before | After |
| --- | --- | --- |
| `background` | `#0B0B0C` | `#0C0B0A` |
| `surfaceDim` | `#0E0E10` | `#0F0E0D` |
| `surfaceLow` | `#111113` | `#121110` |
| `surface` | `#141416` | `#151413` |
| `surfaceHigh` | `#191A1D` | `#1B1A19` |
| `surfaceVariant` | `#1E1E21` | `#1F1E1D` |
| `surfaceBright`, `cardHover`, `shimmerHighlight` | `#26272B` | `#282726` |
| `divider` | `#1D1D21` | `#1E1D1C` |
| `border` | `#2E2E33` | `#2F2E2D` |
| `shimmerBase` | `#1A1A1D` | `#1B1A19` |

A test asserts that adjacent steps from `background` to `surfaceBright` stay
strictly increasing in relative luminance, and that `textSecondary` on
`surfaceVariant` still clears the contrast floor the existing palette tests
use.

## Theme pass (`AppTheme.build`, `liquid: false`)

- **Feedback:** `splashFactory: NoSplash.splashFactory` on the theme and every
  button style (today only Liquid sets it). `overlayColor` resolves hover to
  `hoverOverlay`, pressed to `pressOverlay`, focused to transparent (focus has
  its own ring).
- **Buttons:** radius `radiusControl`. Filled and elevated: white fill, dark
  text, 44 high. Outlined (secondary): white 7% fill, `hairlineStrong` side,
  40 high. Text: no fill. All Inter 600 15, `minimumSize` height kept so the
  hit target is at least 48 on touch.
- **Switch:** 40×24 track, 20 white thumb that slides without resizing, gold
  track when on, `border`-coloured track when off, no outline, no thumb icon.
  Wrapped in a 48 high tap target.
- **Checkbox:** 18 square, radius 5, gold fill with dark check, unchecked edge
  `hairlineStrong`. **Radio:** gold dot, kept for the rare long list; short
  lists move to `AppSegmented`.
- **Popup menu:** `surfaceHigh` fill, radius `radiusMenu`, `hairline` side,
  two-layer shadow (ambient + direct), 40 high items, icon `textSecondary` 18,
  label Inter 500 14.
- **Inputs:** `surfaceLow` fill, radius `radiusControl`, `hairline` side at
  rest, gold 1.5px side on focus, error side on error. No outer focus ring
  (the mockup's soft ring is not expressible in `InputDecorationTheme` and is
  dropped).
- **Tooltip:** `surfaceHigh`, radius 8, `hairline`, 125 ms ease-out.
- **Card / list tile:** radius `radiusMenu`, `hairline` side, no tint.
- **Snackbar theme:** unused by design (toasts below), but themed to match the
  toast in case a stray one shows.
- **Text:** `FontFeature.tabularFigures()` on the default body and label styles,
  so timecodes, durations, sizes and bitrates line up.
- **Section headers:** the settings eyebrow (`SettingsSection`) moves from
  11/600 `textDisabled` with 1.2 tracking to 13/600 `textSecondary` with no
  tracking. The strings are already title case in the ARB files and do not
  change.

## Seams

### `GlassDialog`, Frosted branch

Replaces the `AlertDialog` path. A centred card, max width 340, `surfaceHigh`
fill, radius `radiusModal`, `hairline` side, padding 24/10/10, over the
`scrim`. Optional `icon` in a 44 circle tinted by role (error tint when
`destructive`). Title Inter 600 17, centred; content Inter 13.5
`textSecondary`, centred. Actions are full width and stacked, 44 high, radius
`radiusControl`, gap 8.

Order: callers pass actions in reading order, cancel first and primary last
(the `AlertDialog` convention they follow today). The Frosted stack reverses
them, so the primary action is on top and cancel at the bottom; traversal
follows the visual order. The primary action takes the filled style; with
`destructive` it takes the error tint instead (error at 16% fill, light error
text). The default focus target is chosen by identity, not position, and stays
what it is today: the caller's last action, or the caller's first (cancel) when
`destructive`. The rest of `_GlassDialogState` (the actions container, the
first-frame check) is unchanged. Callers do not change.

Dialogs wider than 340 by content (forms, pickers) keep their content width up
to 560 and lay actions out in a row, end-aligned, when there are exactly two
short actions and the dialog is wider than 420.

### `showGlassSheet`, Frosted branch

`surfaceHigh` fill, top radius `radiusModal`, `hairline` top edge, a 36×4 grab
handle in `border`. Enter and exit use `Cubic(0.32, 0.72, 0, 1)` over 450 ms;
with `ReducedMotion.of(context)` the sheet appears without the slide. Callers
do not change.

### `GlassButton`, `GlassChip`, Frosted branch

`GlassButton`: the outlined (secondary) style above, height 40 unless given.
`GlassChip`: 30 high, radius 8, `hairlineStrong` side, `textPrimary` 12.5/500;
selected is a white fill with dark text. Gold is not used for chips.

### `FocusEmphasis`

The ring stays (gold, offset `gap`, outside the bounds). Scale becomes a size
class instead of the single 1.07:

| `FocusSize` | Scale | For |
| --- | --- | --- |
| `poster` | 1.1 | poster and portrait cards |
| `tile` | 1.05 | landscape tiles, episode thumbs |
| `control` | 1.025 | buttons, rows, chips (default) |

Ring width drops from 4 to 3. The glow becomes optional (`glowColor`, null by
default); poster cards pass their ambient tint. Scale animates over 120 ms
ease-out; traversal itself is not animated. With animations disabled
(`MediaQuery.disableAnimations`) there is no scale, only the ring. Pressing a
focused item scales it to 0.97 of its focused size (composed with
`PressScale`).

### Toasts (`ToastPill`)

Behaviour stays: one toast at a time, the existing queue, timing, swipe and
obstruction handling. The Frosted pill becomes an opaque `surfaceHigh` fill
with a `hairline` edge and a two-layer shadow, no backdrop blur, radius full.
The pill gets `Semantics(liveRegion: true)` if it lacks it.

## New widgets

All in `player/lib/presentation/widgets/controls/`.

### `PressScale`

Wraps any tappable. Scales its child to 0.97 while pressed (pointer down or
Select/Enter held), 120 ms ease-out in, 160 ms out, transform only. Takes no
focus and adds no semantics. Composes with `FocusEmphasis` (outer) so a
focused, pressed item is `focusScale × 0.97`. Used by the seam-owned controls
(dialog actions, `GlassButton`, `GlassChip`), `AppSegmented` and `AppSelect`.
Plain `FilledButton`/`TextButton` call sites get the press dim from the theme
but no scale: `ButtonStyle` cannot express a transform, and wrapping ~90 files
is out of scope.

### `AppSegmented<T>`

For two to four fixed options. A track (`surfaceLow`, `hairlineStrong` inset,
radius 11, padding 3) holding equal segments (min 30 high, 44 hit target); the
selected segment is `surfaceBright` with `rim` and a 1px shadow. One focus stop
for the whole control: Left and Right move the selection directly (D-pad and
keyboard), wrapping is off, Select does nothing extra. Semantics: a group with
one `selected` button per segment. Selection change animates the thumb 160 ms
(none with reduced motion).

Replaces the subtitle-size row's picker dialog (`showSubtitleSizePicker`) with
an inline control showing S, M, L, XL. Any other settings row with two to four
fixed options found during implementation moves too; rows whose options come
from the server (tracks, languages, libraries, qualities) do not.

### `AppSelect<T>`

Replaces the five `DropdownButton`s. A 40 high field (`surfaceLow`,
`hairlineStrong`, radius `radiusControl`) showing the current label and an
up/down chevron. Activating it opens the themed popup menu anchored under the
field, the current value checked. One focus stop; Select opens, the menu
handles its own traversal, Back closes and returns focus to the field.

A call-site test (pattern of the existing GlassDialog/GlassSheet call-site
tests) fails on any `DropdownButton` or direct `AlertDialog` under `lib/`
outside the seams themselves.

## Out of scope

- Liquid Glass, `LiquidGeometry`, the shader, the lab.
- The playback OSD (`GlassSurface.osd`, `playback_chrome.dart`): its own
  material and layout. The mockup's playback screen is reference only.
- Navigation layout (rail, dock, drawer, top bars).
- Toast stacking and new Undo flows.
- Material 3 Expressive springs and shapes; adopt later through these seams
  once they ship in a pinned `material_ui`.
- Live blur on Android TV and web. Nothing here adds a `BackdropFilter`.

## Testing

- Widget tests per seam in both modes: Frosted asserts the new layout (scrim,
  stacked actions, radii, no `InkSplash`/`InkRipple` in the tree); Liquid asserts
  the old tree is unchanged.
- `FocusEmphasis`: scale per `FocusSize`, no scale with animations disabled,
  ring width, glow only when given.
- `AppSegmented` and `AppSelect`: D-pad traversal (one stop each, Left/Right
  change the segment, Select opens the select, Back returns focus), semantics
  (selected state, button roles), reduced motion.
- Palette: monotonic lightness and contrast assertions above.
- Call-site test for `DropdownButton` / `AlertDialog`.
- Existing focus, semantics and call-site tests pass unchanged.
- `./dev player glass-diff` shows no Liquid change.
- Manual: Android TV emulator (`./dev player android tv-run`) walk of settings,
  detail, a destructive dialog, a sheet and a select, counting presses against
  `master`.

## Delivery

One PR if the diff stays reviewable; otherwise two: (1) `SurfaceRoles`,
palette, theme pass and `material_ui` pin; (2) seams, `FocusEmphasis`, new
widgets and the call-site test.
