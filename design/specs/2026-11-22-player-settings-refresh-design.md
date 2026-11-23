# Player settings refresh

Date: 2026-11-22
Status: approved direction, awaiting spec review

## Goal

Make the Flutter player's settings look current. Three things read as dated
today: the desktop dialog's stock `ListTile` sidebar, the row and card
styling, and the information layout (appearance choices live under
Playback, and a few one-value pickers hide behind navigation rows).

Success: every settings surface (desktop dialog, the phone/tablet/TV
`SettingsScreen`, the per-server Mydia instance screen, Add server, the
connections card) shares one refreshed visual language, the dialog gains a
grouped sidebar with live status, and Appearance becomes its own place. No
setting is added or removed, no storage changes, and TV D-pad behaviour is
unchanged.

Mockups (the "A" and "C" boards are the chosen direction):
https://claude.ai/artifact/VDdjrK59esavR8Jzy8jYi9

## Non-goals

- Settings search. The sidebar leaves room for it; a later change can add a
  registry of settings and keywords.
- New settings, new pickers, or changes to what any setting does.
- The web admin settings page (`/admin/settings`).
- An overview hub landing page (mockup "B").

## Shared widgets (all surfaces)

All under `player/lib/presentation/screens/settings/widgets/`.

### `SettingsSection`

- The eyebrow label (11px, w600, 1.2 tracking, `textDisabled`) becomes a
  section header: 13px, w600, no tracking, a lighter tone than body
  secondary text. The string is still rendered as given.
- New optional `footer` string: 12px `textSecondary` line under the card,
  for explanations shared by the rows above it.
- The `FocusMemoryItem` / `SettingsFocusOrder` wrapping is unchanged.

### `SettingsCard`

- Keeps `GlassSurface.faux` (no live blur, no Liquid Glass change, so the
  `glass-diff` hook is not involved).
- 1px `border`-toned outline, corner radius 14 (a new `AppTheme` token,
  `radiusSettingsCard`, rather than reusing `radiusCard` 18).
- Dividers inset 16px from the leading edge instead of full width.

### `SettingsRow`

- The `_IconTile` is removed. `icon` becomes optional and unused; every call
  site drops it in the same PR and the parameter is then deleted, so no dead
  parameter ships.
- Minimum row height 52px; padding 16 horizontal, 12 vertical for every kind
  (toggle rows no longer use the tighter 8px).
- Title 14px w500, subtitle 12.5px `textSecondary`; the status-dot subtitle
  stays.
- Toggle: a compact 40x24 switch (`Switch.adaptive` styled through the
  theme's `switchTheme`, not a hand-drawn widget). The row stays the focus
  target and the switch stays inside `ExcludeFocus`, as today.
- New `SettingsRow.select({title, subtitle, value, onTap})`: the value
  drawn as a bordered button (radius 8, height 30, chevron-down) at the
  trailing edge. `onTap` opens whatever picker the row opened before. The
  whole row remains one focus stop that activates `onTap`; the button is
  decoration, not a second focus target.
- `.navigation` stays for rows that open a genuinely separate page
  (Diagnostics, paired devices, a server). Rows that only pick a value move
  to `.select`: default quality, language, and any other single-value row
  found during implementation.

### `SettingsChoiceGrid` (new)

Radio cards with a visual preview, for choices where seeing beats reading.

- Options laid out in a grid (`columns` parameter; 4 for themes, 2 for
  material), each an `InkWell` option in the `TrackPickerRow` pattern, so
  D-pad focus and activation come for free.
- Selected option: 2px `primary` ring; others 1px `border`.
- Semantics: the group is labelled, each option is a selected/unselected
  radio with its name.
- Used by:
  - **Theme**: one card per `ThemePreset.availableOn(platform)`, preview
    drawn from that preset's palette (background, two surface bars, primary
    dot). Replaces `ThemePresetSettingsRow`'s picker sheet.
    `showThemePresetPicker` is kept only if another caller uses it.
  - **Material**: Liquid Glass vs Frosted, shown only where
    `GlassMaterial.liquid.isAvailableOn` holds, as today. The preview is a
    static drawing, not live glass.
- On a phone narrower than four cards fit, the theme grid wraps to two
  columns.

## Information layout

- New `SettingsCategory.appearance` (sidebar label: the existing
  `settingsAppearanceSection` string) holding Theme, Material and Language.
  `AppearanceSettingsSection` moves out of the Playback pane.
- Playback pane groups: **Video** (default quality, stats for nerds),
  **Skipping** (intros and credits, commercials; the shared "Off shows a
  skip button instead" moves to the section footer), **Remote control**
  (the remote-control switch and its retry row).
- Each dialog pane gets a large title (26px, w700) and a one-line
  description under it, replacing the 56px `AppBar`-style header. The pane's
  back button (nested routes) and close button stay; close becomes a 30px
  circular button.
- On `SettingsScreen` (phone, tablet, TV) the same section split applies:
  Appearance is its own section after Playback, and Playback uses the three
  groups above. `SettingsFocusOrder` positions are renumbered to match.

New strings (pane descriptions, the "Video", "Skipping" and "Remote control"
headers, the skipping footer, the "Update" badge) go in `app_en.arb` with
descriptions, per `player/docs/l10n.md`; Weblate fills the other locales.

## Desktop dialog sidebar

`SettingsDialogSidebar`, 236px wide (compact mode keeps the 64px icon rail).

- **Account card** at the top: initial avatar, username, active server
  name, from the same providers `SettingsIdentity` reads. Activating it
  opens Servers & devices. Hidden when there are several Mydia accounts, the
  rule `SettingsScreen` already applies to `SettingsIdentity`.
- **Categories in two groups** separated by a divider:
  Servers & devices, Backup & sync, Playback, Appearance | Diagnostics,
  About. Servers & devices stays first: `/settings` opens on it and
  `SettingsCategory.values.first` is asserted by the dialog tests. (The
  mockup showed Appearance first; this order wins.)
- Each item: a 24px rounded-square icon tile with a per-category tint
  (muted, similar lightness, defined in one place next to
  `SettingsCategory`), 13.5px label, 34px row, radius 9. Selected: the
  `primary` tint background at 16% and a filled icon tile.
- **Status**: a 7px dot after Servers & devices from the same
  `ConnectionSummary` Diagnostics uses (green connected, amber relayed,
  red unreachable), with a semantic label. An "Update" pill after About when
  `updateProvider` reports an available update.
- Keys `settings-category-<name>` stay on each item.

## Testing

- Update existing widget tests that assert on the removed icon tile,
  eyebrow styling, or the Playback pane containing Appearance:
  `settings_row_test`, `settings_section_test`, `settings_sections_test`,
  `theme_preset_row_test`, `glass_material_row_test`, `language_row_test`,
  `settings_dialog_test`, `settings_screen_test`.
- New tests:
  - `SettingsRow.select` shows its value and activates `onTap` by tap and by
    Enter/select.
  - `SettingsChoiceGrid` selects by tap and by D-pad, exposes radio
    semantics, and shows only the presets available on the platform.
  - The sidebar shows the status dot per connection state, the update pill
    only when an update exists, and hides the account card with several
    accounts.
  - The Appearance category opens its pane, and Playback no longer contains
    theme or language rows.
- `settings_focus_tv_test` and `settings_initial_focus_test` must pass
  unchanged in intent: D-pad order runs section by section, row by row,
  including through the choice grids.
- Visual check: run the player on desktop (dialog, normal and compact) and
  at phone width, and on the Android TV emulator for focus rings on the new
  grid and select rows.

## Risks

- **Every settings surface changes at once.** Add server, the Mydia instance
  screen and the connections card pick up the new rows. That is the intent,
  but each needs a visual pass.
- **TV focus.** The choice grid adds horizontal movement inside a vertical
  list. Following the `TrackPickerRow` pattern keeps it within what
  `FocusMemoryRegion` already handles; the TV focus test is the gate.
- **Removing `icon`.** Rows on screens outside settings pass icons today;
  the removal touches all of them in one PR.
