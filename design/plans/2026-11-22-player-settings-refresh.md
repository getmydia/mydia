# Player Settings Refresh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restyle the Flutter player's settings (shared rows, sections, cards, the desktop dialog and its sidebar) and move Appearance into its own category, without changing what any setting does.

**Architecture:** The shared widgets in `player/lib/presentation/screens/settings/widgets/` change once and every settings surface picks them up. Two new pieces: a `SettingsRow.select` constructor and a `SettingsChoiceGrid` widget. The dialog gains `SettingsCategory.appearance` and a redesigned sidebar that takes plain values (built by a provider-reading wrapper), so it pumps in tests without providers.

**Tech Stack:** Flutter (material_ui), Riverpod, gen_l10n ARB, flutter_test.

**Spec:** `design/specs/2026-11-22-player-settings-refresh-design.md`

## Global Constraints

- No setting is added or removed, and no storage key or provider changes.
- TV D-pad behaviour is unchanged: the whole row is one focus stop; `FocusMemoryItem` / `SettingsFocusOrder` indices stay unique.
- `SettingsCard` stays on `GlassSurface.faux`. Nothing under `lib/core/theme/liquid_glass/` or the glass widgets changes, so `./dev player glass-diff` is not needed. If a task does touch them, run it before committing.
- Every new viewer-facing string goes in `lib/l10n/app_en.arb` with an `@` description (`test/l10n/arb_consistency_test.dart`). Do not edit `app_es.arb` / `app_pt_BR.arb`.
- `SettingsCategory.values.first` stays `connections`; `/settings` still opens on it.
- Keys `settings-category-<name>`, `settings-category-label-<name>`, `settings-dialog-close`, `settings-dialog-back`, `theme-preset-row`, `language-row` and `glass-material-row` are kept (tests and focus code find rows by them).
- No real movie or TV titles in tests or fixtures.
- Run Flutter through the wrapper from the repo root: `./dev flutter test --concurrency=1 <paths>`, `./dev flutter analyze`. Run `./dev player setup` once first in a fresh worktree.
- Commit with plain `git commit -F <msgfile>` from inside the worktree (direnv loaded; the prek hook needs the devenv config). Stage every path first, then check `git show --stat HEAD`.

## Review Focus

1. **TV focus indices after splitting Playback.** Three `SettingsSection`s under one `SettingsFocusOrder` would collide on `order * 100 + i`. Each group gets its own order. Pinned in Task 6 (`playback groups have distinct focus orders`).
2. **Choice grid under D-pad.** Left/right moves between theme cards, and down leaves the grid for the next row instead of trapping focus. Pinned in Task 4.
3. **Presets not offered on this platform** (macOS preset off macOS, Linux preset off Linux) must not appear as cards. Pinned in Task 5.
4. **Narrow widths.** The theme grid at phone width (<400px) wraps to 2 columns, and the compact dialog (<640×420) keeps the 64px icon rail with no account card or badges overflowing. Pinned in Tasks 4 and 8.
5. **Several Mydia accounts.** The sidebar account card is hidden, as `SettingsIdentity` is on the screen. Pinned in Task 8.

---

### Task 1: Section header, footer, and card outline

**Files:**
- Modify: `player/lib/core/theme/app_theme.dart` (radius tokens, ~line 21)
- Modify: `player/lib/presentation/screens/settings/widgets/settings_section.dart`
- Test: `player/test/presentation/screens/settings/widgets/settings_section_test.dart`

**Interfaces:**
- Produces: `AppTheme.radiusSettingsCard = 14.0`; `SettingsSection({required String label, required List<Widget> children, String? footer})`; `SettingsCard` unchanged API.

- [ ] **Step 1: Write the failing tests** in `settings_section_test.dart`:
  - `header is sentence styled`: the label `Text` has `fontSize == 13`, `fontWeight == FontWeight.w600`, and `letterSpacing` null or 0.
  - `footer renders under the card`: `SettingsSection(label: 'Skipping', footer: 'When off, a skip button appears instead.', children: [...])`. The footer text is found, and its `tester.getTopLeft(...).dy` is greater than the card's bottom.
  - `no footer, no extra text`: without `footer`, the only `Text` widgets are the label and the children's.
  - `card dividers are inset 16`: with two children, the `Divider` has `indent == 16`.
- [ ] **Step 2: Run to confirm they fail.** `./dev flutter test --concurrency=1 test/presentation/screens/settings/widgets/settings_section_test.dart` should fail on the header style, the missing `footer` param, and the indent.
- [ ] **Step 3: Implement.**
  - Add `radiusSettingsCard`.
  - Header: 13px w600, colour `palette.textPrimary` at 0.8 alpha, padding `fromLTRB(2, 0, 2, 8)`.
  - `footer`: 12px `textSecondary`, top padding 8, horizontal 2.
  - `SettingsCard`: radius `radiusSettingsCard`, a 1px `palette.border` outline at 0.6 alpha (via `GlassSurface.faux`'s border parameter if it has one, else a `DecoratedBox` foreground), `Divider(indent: 16)`.
  - Leave the focus-order wrapping untouched.
- [ ] **Step 4: Run the file again, plus `settings_screen_test.dart` and `settings_focus_tv_test.dart`.** All should pass. Fix any assertion that pinned the old 11px eyebrow, changing the expected value and nothing else.
- [ ] **Step 5: Commit.** `style(player): sentence-case settings headers and outlined cards`

### Task 2: Row restyle and `SettingsRow.select`

**Files:**
- Modify: `player/lib/presentation/screens/settings/widgets/settings_row.dart`
- Modify: `player/lib/core/theme/app_theme.dart` (`switchTheme`, ~line 431)
- Test: `player/test/presentation/screens/settings/widgets/settings_row_test.dart`

**Interfaces:**
- Produces:
  - `SettingsRow.select({Key? key, IconData? icon, required String title, String? subtitle, required String value, required VoidCallback? onTap})`
  - `icon` becomes `IconData?` on every constructor. It is ignored from now on and deleted in Task 3.
  - The row's select button carries `Key('settings-row-select-value')`.

- [ ] **Step 1: Write the failing tests:**
  - `no icon tile is drawn`: `.navigation(icon: Icons.hd, ...)` → `find.byIcon(Icons.hd)` finds nothing.
  - `rows are at least 52 tall`: `tester.getSize(find.byType(SettingsRow)).height >= 52` for navigation, toggle and action rows.
  - `select shows value and chevron-down`: `.select(title: 'Default quality', value: 'Auto', onTap: ...)` → `find.text('Auto')`, `find.byIcon(Icons.expand_more)`, no `Icons.chevron_right`.
  - `select activates by tap and by Enter`: tap the row, then focus its node (`_node` helper) and send `LogicalKeyboardKey.enter` → the tap counter is 2.
  - `select value button is not a second focus stop`: the number of focusable nodes under the row is 1.
  - `null onTap dims select`: `Opacity.opacity == 0.45`.
- [ ] **Step 2: Run to confirm they fail.** `./dev flutter test --concurrency=1 test/presentation/screens/settings/widgets/settings_row_test.dart`
- [ ] **Step 3: Implement.**
  - Delete `_IconTile`.
  - Padding `symmetric(horizontal: 16, vertical: 12)` for every kind, `minHeight: 52 - 24`. Title 14px w500, subtitle unchanged.
  - Add `_RowKind.select`, with a trailing `_SelectValue`: height 30, radius 8, a 1px `palette.border` outline on `palette.surfaceHigh`, 13px value text, `Icons.expand_more` at 16px in `textSecondary`. Wrap it in `ExcludeFocus`.
  - Dimming rule: a `.select` row dims when `onTap` is null, like `.navigation`.
  - In `switchTheme`, a compact switch: `materialTapTargetSize: shrinkWrap`, thumb icon none. Wrap the row's `Switch` in `Transform.scale(scale: 0.78)` so it renders about 40×24; don't hand-draw a switch.
- [ ] **Step 4: Run the row tests, then the whole `test/presentation/screens/settings/` folder.** Update any test that found rows by their icon, finding them by title or key instead.
- [ ] **Step 5: Commit.** `feat(player): flatter settings rows and a select row`

### Task 3: Remove `icon` from `SettingsRow`

**Files:**
- Modify: `settings_row.dart` and every caller. The counts per file are:
  - `lib/presentation/screens/sources/add_source_screen.dart` (9)
  - `lib/presentation/screens/settings/diagnostics_screen.dart` (10)
  - `lib/presentation/screens/settings/widgets/settings_sections.dart` (8)
  - `lib/presentation/screens/sources/mydia_instance_screen.dart` (5)
  - `lib/presentation/screens/settings/widgets/diagnostics_sharing_section.dart` (3)
  - `lib/presentation/screens/connections/connections_constellation_card.dart` (1)
  - `lib/presentation/screens/settings/settings_screen.dart` (1)
  - `lib/presentation/screens/settings/widgets/glass_material_row.dart` (1)
  - `lib/presentation/screens/settings/widgets/language_row.dart` (1)
  - `lib/presentation/screens/settings/widgets/subtitle_size_row.dart` (1)
  - `lib/presentation/screens/settings/widgets/theme_preset_row.dart` (1)
  - and every test that passes `icon:`.

**Interfaces:**
- Produces: `SettingsRow` constructors with no `icon` parameter.

- [ ] **Step 1: Delete the `icon` field and parameter from all four constructors.**
- [ ] **Step 2: Find the callers.** Run `./dev flutter analyze` and collect the `undefined_named_parameter` errors.
- [ ] **Step 3: Remove `icon: ...,` at each reported call site, in `lib/` and `test/`.** Drop the `Icons` imports that become unused.
- [ ] **Step 4: Verify.** `./dev flutter analyze` reports no issues, and `./dev flutter test --concurrency=1 test/presentation/screens/settings test/presentation/screens/sources test/presentation/screens/connections` passes.
- [ ] **Step 5: Commit.** `refactor(player): drop the unused settings row icon`

### Task 4: `SettingsChoiceGrid`

**Files:**
- Create: `player/lib/presentation/screens/settings/widgets/settings_choice_grid.dart`
- Test: `player/test/presentation/screens/settings/widgets/settings_choice_grid_test.dart`

**Interfaces:**
- Produces:
  ```dart
  class SettingsChoice<T> {
    const SettingsChoice({required this.value, required this.label, this.description, required this.preview});
    final T value; final String label; final String? description; final Widget preview;
  }
  class SettingsChoiceGrid<T> extends StatelessWidget {
    const SettingsChoiceGrid({super.key, required this.label, required this.choices,
      required this.selected, required this.onSelected, this.columns = 4, this.layout = SettingsChoiceLayout.stacked});
    final String label;               // group semantics label
    final List<SettingsChoice<T>> choices;
    final T selected;
    final ValueChanged<T> onSelected;
    final int columns;                // drops to 2 below 400px of available width
    final SettingsChoiceLayout layout; // stacked: preview above label (themes); inline: preview left of label+description (material)
  }
  enum SettingsChoiceLayout { stacked, inline }
  ```
  Each option carries `Key('settings-choice-<index>')`.

- [ ] **Step 1: Write the failing tests:**
  - `tap selects`: tapping `settings-choice-2` calls `onSelected` with choice 2's value.
  - `selected option has a primary ring`: the selected option's `DecoratedBox`/border colour is `palette.primary` at width 2, and the others have width 1.
  - `radio semantics`: `tester.getSemantics(find.byKey(Key('settings-choice-0')))` matches `isInMutuallyExclusiveGroup: true, hasCheckedState: true, isChecked: true` on the selected option.
  - `arrow keys move between options and Enter selects`: focus option 0, send `arrowRight`, then `enter`; `onSelected` gets option 1.
  - `down leaves the grid`: with a `TextButton` below the grid, focus the last option and send `arrowDown`; the button has focus.
  - `wraps to two columns when narrow`: pumped in a 360px-wide box with 4 choices, option 2's `dy` is greater than option 0's.
- [ ] **Step 2: Run to confirm they fail.**
- [ ] **Step 3: Implement.**
  - Lay out with `LayoutBuilder` + `Wrap` (or `GridView.count` with `shrinkWrap`). Gap 10.
  - Each option is a `FocusHighlight(onActivate: ...)` around an `InkWell(canRequestFocus: false)`, as in `SettingsRow`, inside `Semantics(inMutuallyExclusiveGroup: true, checked: ..., label: choice.label)`. The group is wrapped in `Semantics(label: label, container: true)`.
  - Stacked layout: preview 72 tall, radius 12, label 12.5px below it, w600 when selected.
  - Inline layout: 12px padding, a 44×44 preview, then label (13.5px w600) and description (12px `textSecondary`).
- [ ] **Step 4: Run the tests.** They pass.
- [ ] **Step 5: Commit.** `feat(player): settings choice grid`

### Task 5: Appearance controls (theme, material, language) and the quality select

**Files:**
- Modify: `player/lib/presentation/screens/settings/widgets/theme_preset_row.dart`
- Modify: `player/lib/presentation/screens/settings/widgets/glass_material_row.dart`
- Modify: `player/lib/presentation/screens/settings/widgets/language_row.dart`
- Modify: `player/lib/presentation/screens/settings/widgets/settings_sections.dart` (the quality row)
- Create: `player/lib/presentation/screens/settings/widgets/theme_preset_preview.dart`
- Test: `theme_preset_row_test.dart`, `glass_material_row_test.dart`, `language_row_test.dart`, `settings_sections_test.dart`

**Interfaces:**
- Consumes: `SettingsChoiceGrid` (Task 4), `SettingsRow.select` (Task 2).
- Produces:
  - `ThemePresetSettingsRow` (the name is kept) renders a `SettingsChoiceGrid<ThemePreset>` with key `theme-preset-row`.
  - `GlassMaterialSettingsRow` renders a 2-column inline `SettingsChoiceGrid<GlassMaterial>` with key `glass-material-row`, still returning `SizedBox.shrink()` where Liquid isn't available.
  - `ThemePresetPreview({required MydiaPalette palette})`: background, two surface bars, a 22px primary dot.

- [ ] **Step 1: Write the failing tests:**
  - Theme: one `settings-choice-*` per `ThemePreset.availableOn(defaultTargetPlatform)`, and none for presets outside it. Run with `debugDefaultTargetPlatformOverride = TargetPlatform.android` and assert that `macOS` is absent. Selecting a card writes through `themePresetSettingProvider` (override the notifier as the existing test does).
  - Material: two choices labelled with `glassMaterialName(liquid)` and `glassMaterialName(frosted)`. Selecting Frosted sets `GlassMaterial.frosted`. `debugIsTv: true` still renders nothing.
  - Language: the row is a `.select` row (`find.byKey(Key('settings-row-select-value'))` inside `language-row`) showing `System default`, and tapping it still opens the picker.
  - Quality: the default-quality row is a `.select` row showing the current rung's label.
- [ ] **Step 2: Run to confirm they fail.**
- [ ] **Step 3: Implement.**
  - The theme previews use `preset.palette(systemAccent: ..., linuxDesktop: ..., linuxAccent: ...)` with the same providers the theme already reads (`linuxDesktopProvider`, the accent providers in `theme_providers.dart`).
  - Material previews are static decorations: liquid is a two-tone gradient with a translucent pill; frosted is a flat pill. No `BackdropFilter`.
  - Language and quality switch `.navigation` → `.select`, keeping the same `onTap` bodies.
  - If `showThemePresetPicker` has no remaining caller (`grep -rn showThemePresetPicker lib`), delete it together with its widget file and test.
- [ ] **Step 4: Run all four test files plus `settings_screen_test.dart`.** They pass.
- [ ] **Step 5: Commit.** `feat(player): pick theme and material from previews`

### Task 6: Playback groups and the Appearance section

**Files:**
- Modify: `player/lib/presentation/screens/settings/widgets/settings_sections.dart`
- Modify: `player/lib/presentation/screens/settings/settings_screen.dart` (~lines 176-188)
- Modify: `player/lib/presentation/screens/settings/dialog/settings_panes.dart` (`_PlaybackPage`)
- Modify: `player/lib/l10n/app_en.arb`
- Test: `settings_sections_test.dart`, `settings_screen_test.dart`, `settings_focus_tv_test.dart`

**Interfaces:**
- Produces. `PlaybackSettingsSection` is replaced by three widgets with the same `settings` / `failed` inputs:
  - `PlaybackVideoSection({required UserSettings? settings, required bool failed})`: default quality and stats for nerds, label `settingsPlaybackVideoSection`.
  - `PlaybackSkippingSection({...same})`: intros/credits and commercials, label `settingsPlaybackSkippingSection`, footer `settingsAutoSkipFooter`. The rows drop their individual "Off shows a skip button instead" subtitles.
  - `RemoteControlSection()`: the remote-control switch and its retry row, label `settingsRemoteControlSection`.
  - The preferences-failed row stays in `PlaybackVideoSection`.
  - ARB keys, English: `settingsPlaybackVideoSection` "Video", `settingsPlaybackSkippingSection` "Skipping", `settingsRemoteControlSection` "Remote control", `settingsAutoSkipFooter` "When off, a skip button appears instead."

- [ ] **Step 1: Write the failing tests:**
  - `playback groups render under their headers`: pump the dialog's Playback page. It shows `Video`, `Skipping` and `Remote control`, and has no `theme-preset-row` or `language-row`.
  - `skipping footer replaces row subtitles`: `find.text('Off shows a skip button instead')` finds nothing, and the footer finds one.
  - `playback groups have distinct focus orders` (in `settings_focus_tv_test.dart`): collect every `FocusMemoryItem.index` on the TV `SettingsScreen` and assert they are all unique. The Appearance rows' indices are greater than the Skipping rows'.
  - On the mobile `SettingsScreen`, Remote control stays in the Manage section. Assert it is not under a `Remote control` header there.
- [ ] **Step 2: Run to confirm they fail.**
- [ ] **Step 3: Implement.**
  - On `SettingsScreen`, the order is `section(1, PlaybackVideoSection)`, `section(2, PlaybackSkippingSection)`, `section(3, AppearanceSettingsSection)`, `section(4, _ManageSection)`. `_ManageSection` keeps the remote-control rows it has today.
  - Dialog `_PlaybackPage`: Video, Skipping and RemoteControl, 22px apart. Appearance leaves this page (Task 7 gives it its own).
  - Remove `includeRemoteControl`.
  - Add the four ARB entries with `@` descriptions, then run `./dev flutter pub get` to regenerate.
- [ ] **Step 4: Run the three test files and `test/l10n/`.** They pass.
- [ ] **Step 5: Commit.** `feat(player): group playback settings and split appearance out`

### Task 7: Appearance category and the pane header

**Files:**
- Modify: `player/lib/presentation/screens/settings/dialog/settings_dialog.dart` (`SettingsCategory`, `SettingsPane`)
- Modify: `player/lib/presentation/screens/settings/dialog/settings_panes.dart` (`settingsRootPage`, `_CategoryPane`)
- Modify: `player/lib/presentation/screens/settings/dialog/open_settings.dart` (the exhaustive switch at ~line 130)
- Modify: `player/lib/l10n/app_en.arb`
- Test: `player/test/presentation/screens/settings/dialog/settings_dialog_test.dart`, `open_settings_test.dart`

**Interfaces:**
- Produces:
  - `SettingsCategory` order: `connections, backup, playback, appearance, diagnostics, about`. `appearance` uses `Icons.palette_outlined` and its label is `l10n.settingsAppearanceSection`.
  - `SettingsCategory.description(AppLocalizations)` returns the pane's one-line description.
  - `bool get SettingsCategory.startsGroup`: true for `diagnostics`.
  - `SettingsPane({required String? title, String? description, List<Widget> actions, required Widget child})`.
  - ARB keys: `settingsBackupDescription`, `settingsPlaybackDescription` "How titles play on this device.", `settingsAppearanceDescription` "The look of Mydia on this device.", `settingsDiagnosticsDescription`, `settingsAboutDescription`. Connections has none: its page opens with its own constellation.

- [ ] **Step 1: Write the failing tests:**
  - `appearance pane holds theme, material and language`: select `settings-category-appearance`; `theme-preset-row` and `language-row` are found.
  - `pane title is large with its description`: on Playback, the title `Text` has `fontSize == 26` and `fontWeight == FontWeight.w700`, and `How titles play on this device.` is found.
  - `close is a compact round button`: `tester.getSize(find.byKey(Key('settings-dialog-close')))` is 30×30.
  - `back still appears on a nested route`: an existing test. It must keep passing.
  - `open_settings`: on mobile, `openSettings(initial: SettingsCategory.appearance)` routes to `/settings`.
- [ ] **Step 2: Run to confirm they fail.**
- [ ] **Step 3: Implement.**
  - `SettingsPane`:
    - Header: back button (when it can pop) plus the close button in a 52px top row.
    - Title (26px w700, letterSpacing -0.4) and description (13.5px `textSecondary`) at the top of the body, inside the existing body padding, which becomes `fromLTRB(40, 4, 40, 24)`, with the content constrained to `maxWidth: 600`.
    - Close is an `IconButton.filledTonal` with `fixedSize` 30 and a 15px icon.
  - `settingsRootPage` gains `appearance => _CategoryPane(category: appearance, child: ListView(padding: _bodyPadding, children: [AppearanceSettingsSection()]))`.
  - `open_settings.dart`: `playback || appearance || about` → `router.go('/settings')`.
- [ ] **Step 4: Run the `test/presentation/screens/settings/dialog/` folder.** It passes.
- [ ] **Step 5: Commit.** `feat(player): Appearance settings category and larger pane titles`

### Task 8: Sidebar redesign

**Files:**
- Modify: `player/lib/presentation/screens/settings/dialog/settings_dialog_sidebar.dart`
- Create: `player/lib/presentation/screens/settings/dialog/settings_sidebar_status.dart` (provider-reading wrapper)
- Modify: `player/lib/presentation/screens/settings/dialog/settings_dialog.dart` (sidebar construction, `width` 236)
- Modify: `player/lib/presentation/screens/settings/dialog/open_settings.dart` (pass `router` location)
- Modify: `player/lib/l10n/app_en.arb`
- Test: `player/test/presentation/screens/settings/dialog/settings_dialog_sidebar_test.dart` (new)

**Interfaces:**
- Consumes: `SettingsCategory.startsGroup` (Task 7), `ConnectionStatusDot` (`lib/presentation/widgets/connection_status_dot.dart`), `connectionToneColor`, `updateProvider.availableUpdate`, the providers `SettingsScreen` reads for `SettingsIdentity` and `mydiaAccountCountProvider`.
- Produces:
  ```dart
  class SettingsSidebarAccount { const SettingsSidebarAccount({required this.username, required this.serverUrl}); final String username; final String serverUrl; }
  SettingsDialogSidebar({required SettingsCategory selected, required bool compact,
    required ValueChanged<SettingsCategory> onSelect,
    SettingsSidebarAccount? account,     // null hides the card
    Widget? connectionStatus,            // drawn after Servers & devices
    bool updateAvailable = false})       // "Update" pill after About
  class SettingsSidebarStatus extends ConsumerWidget  // reads providers, builds SettingsDialogSidebar
  ```
  - ARB key: `settingsUpdateBadge` "Update".
  - Keys: `settings-sidebar-account`, `settings-sidebar-update-badge`.
  - The account card's text is the username, plus the server URL's host (`Uri.tryParse(serverUrl)?.host ?? serverUrl`), as `SettingsIdentity` shows it.

- [ ] **Step 1: Write the failing tests** (pump `SettingsDialogSidebar` directly, no providers):
  - `categories in two groups`: a `Divider` sits between `settings-category-appearance` and `settings-category-diagnostics`, measured by `dy`.
  - `selected item is tinted`: the selected item's background is `primary` at 0.16 alpha.
  - `account card shows name and host; tapping opens connections`: with `serverUrl: 'https://media.example.test'` it shows `media.example.test`, and the tap calls `onSelect(SettingsCategory.connections)`.
  - `no account, no card`: `account: null` → `settings-sidebar-account` is absent.
  - `update pill only when available`: present with `updateAvailable: true`, absent otherwise.
  - `connection status renders after servers`: pass `const SizedBox(key: Key('status'))`; it is a descendant of the `settings-category-connections` item.
  - `compact keeps the icon rail`: at `compact: true`, the width is 64, no account card or pill, and every category has a tooltip.
  - `SettingsSidebarStatus hides the account with several accounts`: override `mydiaAccountCountProvider` to 2, and the account card is absent.
- [ ] **Step 2: Run to confirm they fail.**
- [ ] **Step 3: Implement.**
  - Items: 34px tall, radius 9, a 24px icon tile (radius 7) with the category tint, and a 13.5px label.
  - Tints live in a `SettingsCategory.tint(MydiaPalette)` extension in the sidebar file: muted backgrounds at similar lightness (connections teal `#1F3330` / `#7CC7B6`, backup blue `#1E2C40` / `#82AEEA`, playback amber from `primary`, appearance slate `#2B2F3A` / `#A9B6D4`, diagnostics violet `#2E2638` / `#B9A2DA`, about neutral `surfaceBright` / `textSecondary`). On the selected item, the tile fills with its foreground colour and the icon uses the background colour.
  - The status dot is `ConnectionStatusDot(location: <the shell location>)`. Pass the location from `openSettings`, where `router` is already captured (`router.routeInformationProvider.value.uri.toString()`), through `SettingsDialog` to `SettingsSidebarStatus`.
  - The account card is 34px avatar plus two lines, radius 12, on `surfaceHigh`.
- [ ] **Step 4: Run the new test file and `test/presentation/screens/settings/dialog/`.** They pass.
- [ ] **Step 5: Commit.** `feat(player): grouped settings sidebar with account and status`

### Task 9: Whole-suite and visual verification

**Files:** none new.

- [ ] **Step 1: Static analysis.** `./dev flutter analyze` reports `No issues found!`.
- [ ] **Step 2: Full test suite.** `./dev player test` passes.
- [ ] **Step 3: Desktop check.** Run the player on desktop (`./dev player macos run` on the Mac, or the web player via `./dev up -d` at `/player`) and open settings with Ctrl+,. Check:
  - every category at 880×600;
  - the compact dialog, by narrowing the window below 640px;
  - the Add server and Mydia instance screens;
  - the phone layout at 390px width.

  Compare against the A and C boards in the spec's mockup link.
- [ ] **Step 4: TV check.** On the Android TV emulator (`./dev player android tv-run`), walk Settings with the D-pad: the theme grid left/right, down out of the grid, and the select rows open their pickers.
- [ ] **Step 5: Fix and commit.** Commit any fixes as `fix(player): ...`, and confirm `git status --porcelain` is clean.
