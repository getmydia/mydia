# Player Linux Native Theme Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `linux` theme preset to the Flutter player that uses the detected desktop's dark greys (Adwaita, Breeze, elementary) and the live desktop accent from the XDG Settings portal, and make it the Linux default.

**Architecture:** `LinuxDesktop` parses `XDG_CURRENT_DESKTOP` into a desktop with a stock accent and display name. `LinuxAccent` reads `org.freedesktop.appearance` / `accent-color` from the Settings portal through a small injectable client and follows `SettingChanged`. `Palettes.linux` builds the palette, and a `presetPaletteProvider` family replaces the per-preset special-casing in the `palette` provider and the picker swatch.

**Tech Stack:** Flutter, Riverpod (hand-written notifiers for `Color` state), `dbus` 0.7.x, `material_color_utilities`, flutter gen-l10n.

**Spec:** `design/specs/2026-11-07-player-linux-native-theme-design.md`

## Global Constraints

- All presets are dark; `color-scheme` is not read.
- `linux` is offered only when `!isWeb && platform == TargetPlatform.linux`; it is appended last to `ThemePreset`.
- `defaultFor`: `macos` where available, else `linux` where available, else `projectionBooth`. A stored pick wins.
- Portal: bus name `org.freedesktop.portal.Desktop`, path `/org/freedesktop/portal/desktop`, interface `org.freedesktop.portal.Settings`, namespace `org.freedesktop.appearance`, key `accent-color`, value `(ddd)` in [0, 1]; any component outside [0, 1] means unset.
- Stock accents: gnome and other `#3584E4`, kde `#3DAEE9`, elementary `#3689E6`.
- Accent contrast target 4.55:1 against the palette background and the OSD worst case.
- Linux palettes have `ambientTint: false`.
- No new Flatpak `finish-args`. No changes to Liquid Glass or `depth_tokens.dart`.
- Tests: `./dev flutter test --concurrency=1 <paths>` (runs in `player/`; paths are player-relative). Never omit `--concurrency=1`.
- Analyze: `./dev flutter analyze --fatal-infos` must stay at "No issues found!".
- Commit from the worktree with direnv loaded: `direnv exec . git commit -F <msgfile>`. Never `--no-verify`. Verify with `git show --stat HEAD`.
- Never use real movie or TV titles in tests. No em dashes in comments or copy.

## Review Focus

1. **No portal or no session bus** (CI, a bare X session, a desktop without xdg-desktop-portal): the app must start normally on the stock accent, with no unhandled async error. Test in Task 2.
2. **A `SettingChanged` for another key** (`color-scheme`, `contrast`) or another namespace must not change the accent. Test in Task 2.
3. **A signal that lands before the initial read answers** must not be overwritten by the late read. Test in Task 2.
4. **Extreme accents** (near-black `#1A1A1A`, pale yellow `#F6D32D`): the lifted accent must clear 4.55:1 on every Linux background, and `onPrimary` must stay readable on it. Test in Task 3.
5. **A stored `linux` preset read on macOS, Android or web** must resolve to that platform's default, not crash or show a Linux palette. Test in Task 4.

---

### Task 1: LinuxDesktop

**Files:**
- Create: `player/lib/core/theme/linux_desktop.dart`
- Test: `player/test/core/theme/linux_desktop_test.dart`

**Interfaces:**
- Produces:
  - `enum LinuxDesktop { gnome, kde, elementary, other }`
  - `static LinuxDesktop LinuxDesktop.parse(String? xdgCurrentDesktop)`
  - `Color get stockAccent`
  - `String? get displayName`: `'GNOME'`, `'KDE Plasma'`, `'elementary OS'`, `null` for `other`
  - `final linuxDesktopProvider = Provider<LinuxDesktop>(...)`: `other` on web, else `parse(Platform.environment['XDG_CURRENT_DESKTOP'])`

- [ ] **Step 1: Write the failing test**

```dart
test('parse maps XDG_CURRENT_DESKTOP entries', () {
  expect(LinuxDesktop.parse('GNOME'), LinuxDesktop.gnome);
  expect(LinuxDesktop.parse('ubuntu:GNOME'), LinuxDesktop.gnome);
  expect(LinuxDesktop.parse('GNOME-Classic:GNOME'), LinuxDesktop.gnome);
  expect(LinuxDesktop.parse('Pantheon:GNOME'), LinuxDesktop.elementary);
  expect(LinuxDesktop.parse('GNOME:Pantheon'), LinuxDesktop.elementary);
  expect(LinuxDesktop.parse('KDE'), LinuxDesktop.kde);
  expect(LinuxDesktop.parse('kde'), LinuxDesktop.kde);
  expect(LinuxDesktop.parse('XFCE'), LinuxDesktop.other);
  expect(LinuxDesktop.parse(''), LinuxDesktop.other);
  expect(LinuxDesktop.parse(null), LinuxDesktop.other);
});

test('stock accents and names', () {
  expect(LinuxDesktop.gnome.stockAccent, const Color(0xFF3584E4));
  expect(LinuxDesktop.other.stockAccent, const Color(0xFF3584E4));
  expect(LinuxDesktop.kde.stockAccent, const Color(0xFF3DAEE9));
  expect(LinuxDesktop.elementary.stockAccent, const Color(0xFF3689E6));
  expect(LinuxDesktop.kde.displayName, 'KDE Plasma');
  expect(LinuxDesktop.other.displayName, isNull);
});
```

Note `GNOME:Pantheon`: Pantheon wins wherever it appears, so `parse` scans all entries for elementary first, then kde, then gnome.

- [ ] **Step 2: Run it and see it fail**

Run: `./dev flutter test --concurrency=1 test/core/theme/linux_desktop_test.dart`
Expected: compile failure, `linux_desktop.dart` not found.

- [ ] **Step 3: Implement `linux_desktop.dart`**

Match entries with `toLowerCase()`: `pantheon` gives elementary, `kde` gives kde, anything starting with `gnome` gives gnome. Import `dart:io` for `Platform` and guard it with `kIsWeb`.

- [ ] **Step 4: Run the test and see it pass**

Same command. Expected: all pass.

- [ ] **Step 5: Commit**

`feat(player): detect the Linux desktop for theming`

---

### Task 2: LinuxAccent

**Files:**
- Create: `player/lib/core/theme/linux_accent.dart`
- Test: `player/test/core/theme/linux_accent_test.dart`

**Interfaces:**
- Produces:
  - `Color? decodePortalAccent(DBusValue value)`
  - `abstract interface class PortalSettingsClient { Future<DBusValue> readOne(String namespace, String key); Future<DBusValue> read(String namespace, String key); Stream<PortalSettingChange> get changes; Future<void> close(); }`
  - `typedef PortalSettingChange = ({String namespace, String key, DBusValue value});`
  - `class DBusPortalSettingsClient implements PortalSettingsClient`: wraps `DBusClient.session()` and a `DBusRemoteObject` on the constants in Global Constraints; `changes` comes from `DBusRemoteObjectSignalStream` on `SettingChanged` (signature `ssv`).
  - `final portalSettingsClientProvider = Provider<PortalSettingsClient>(...)`: creates a `DBusPortalSettingsClient` and closes it in `ref.onDispose`.
  - `final linuxAccentProvider = NotifierProvider<LinuxAccent, Color?>(LinuxAccent.new);`
  - `class LinuxAccent extends Notifier<Color?>` with `@visibleForTesting static bool? debugIsNativeLinux`

- [ ] **Step 1: Write the failing decode tests**

```dart
DBusValue rgb(double r, double g, double b) =>
    DBusStruct([DBusDouble(r), DBusDouble(g), DBusDouble(b)]);

test('decodes a plain struct, rounding to 8 bits', () {
  expect(decodePortalAccent(rgb(0.2078, 0.5176, 0.8941)),
      const Color(0xFF3584E4));
});
test('unwraps variants, including Read\'s double wrap', () {
  expect(decodePortalAccent(DBusVariant(DBusVariant(rgb(1, 0, 0)))),
      const Color(0xFFFF0000));
});
test('out of range means unset', () {
  expect(decodePortalAccent(rgb(-1, -1, -1)), isNull);
  expect(decodePortalAccent(rgb(0.5, 1.2, 0.5)), isNull);
});
test('wrong shapes are null', () {
  expect(decodePortalAccent(DBusStruct([DBusDouble(1), DBusDouble(1)])), isNull);
  expect(decodePortalAccent(DBusString('blue')), isNull);
  expect(decodePortalAccent(DBusStruct([DBusInt32(1), DBusInt32(1), DBusInt32(1)])), isNull);
});
```

- [ ] **Step 2: Write the failing notifier tests**

Use a `_FakePortal implements PortalSettingsClient` with a `StreamController<PortalSettingChange>.broadcast()`, a `Completer<DBusValue>` for `readOne`, an optional `read` result, a `throwUnknownMethod` flag (throws `DBusUnknownMethodException`) and a `closed` flag. Override `portalSettingsClientProvider` with it. `tearDown` resets `LinuxAccent.debugIsNativeLinux = null`.

- `off Linux it is null and never builds the client`: `debugIsNativeLinux = false`; the override factory sets a flag; after reading the provider and pumping a microtask, the flag is false and the state is null.
- `takes the read value, then follows SettingChanged`: complete `readOne` with `rgb(1,0,0)`, expect `0xFFFF0000`; emit `(namespace: 'org.freedesktop.appearance', key: 'accent-color', value: DBusVariant(rgb(0,1,0)))`, expect `0xFF00FF00`.
- `falls back to Read on UnknownMethod`: `readOne` throws `DBusUnknownMethodException`; `read` returns `DBusVariant(DBusVariant(rgb(0,0,1)))`, expect `0xFF0000FF`.
- **Review Focus 1** `no portal: stays null without an unhandled error`: `readOne` and `read` both throw a `DBusMethodResponseException`-like error (and a second variant: the factory itself throws `SocketException`). Run inside `runZonedGuarded` and collect errors; expect the state null and no collected errors.
- **Review Focus 2** `ignores other keys and namespaces`: after the read sets red, emit `color-scheme` in the appearance namespace and `accent-color` in `org.gnome.desktop.interface`; the state is still red.
- **Review Focus 3** `a signal before the read is not overwritten`: emit green, then complete `readOne` with red; the state is green.
- `an unset accent from the portal is null`: emit `rgb(-1,-1,-1)` after a red read; the state is null.
- `disposal closes the client`: dispose the container; `closed` is true.

- [ ] **Step 3: Run them and see them fail**

Run: `./dev flutter test --concurrency=1 test/core/theme/linux_accent_test.dart`
Expected: compile failure.

- [ ] **Step 4: Implement `linux_accent.dart`**

`build()`: return null off native Linux (`debugIsNativeLinux ?? (!kIsWeb && defaultTargetPlatform == TargetPlatform.linux)`). Otherwise `ref.read` the client inside a try (a factory throw is logged and returns null), subscribe to `changes` first, filtered on namespace and key, setting a `_signalled` flag. Then `unawaited` a read: `readOne`, with `read` on `DBusUnknownMethodException`. Apply its result only if `!_signalled && ref.mounted`. Catch every error and log it once with `debugPrint('[LinuxAccent] ...')`. Cancel the subscription in `ref.onDispose`. The client provider owns `close()`. It is hand-written for the same `InvalidTypeException` reason as `SystemAccent`; the doc comment says so.

- [ ] **Step 5: Run the tests and see them pass**

Same command. Expected: all pass.

- [ ] **Step 6: Commit**

`feat(player): read the desktop accent from the XDG Settings portal`

---

### Task 3: Linux palettes and the generalised accent lift

**Files:**
- Modify: `player/lib/core/theme/palette.dart` (`legibleAccent` around 242, `macos` around 259, new `linux`)
- Test: `player/test/core/theme/palette_test.dart`

**Interfaces:**
- Consumes: `LinuxDesktop`, `stockAccent` (Task 1)
- Produces:
  - `static Color Palettes.legibleAccent(Color accent, {required Color background})` (`@visibleForTesting` kept)
  - `static MydiaPalette Palettes.linux(LinuxDesktop desktop, Color? accent)`

- [ ] **Step 1: Verify the ramp anchors upstream**

Check the spec's anchor colours against libadwaita `src/stylesheet/_colors.scss` (dark: `view_bg`, `window_bg`, `headerbar_bg`, `dialog_bg`), Breeze `colors/BreezeDark.colors` (`[Colors:View]`, `[Colors:Window]`, `[Colors:Button]` BackgroundNormal, ForegroundNormal and ForegroundInactive), and elementary `stylesheet` dark palette. Where an upstream anchor differs, use the upstream value, keep the interpolated steps strictly rising in luminance, and update the spec's table in this same task.

- [ ] **Step 2: Write the failing tests**

- `Linux Adwaita ramp is pinned`, `Linux Breeze ramp is pinned`, `Linux elementary ramp is pinned`: one `expect` per field with the Step 1 values (the spec table, unless corrected), in the style of the existing Projection Booth test, with `ambientTint` false. `other` equals `gnome` apart from the accent source.
- `Linux palettes rise in luminance`: for every `LinuxDesktop`, `Palettes.linux(d, null).surfaceTones` is strictly rising, reusing the existing helper from the `ThemePreset.values` loop.
- `a null accent uses the desktop's stock accent, lifted`: `Palettes.linux(d, null).primary == Palettes.legibleAccent(d.stockAccent, background: Palettes.linux(d, null).background)`.
- **Review Focus 4** `extreme accents stay legible`: for every desktop and each of `#1A1A1A`, `#F6D32D`, `#3584E4`, `#3DAEE9`, `primary` clears 4.55 against `background` (use `contrastRatio`), and `contrastRatio(onPrimary, primary) >= 4.5`.
- `legibleAccent leaves a legible accent alone`: an accent that already clears both backgrounds comes back identical.
- Existing macOS tests: update `legibleAccent(x)` calls to pass `background: const Color(0xFF1E1E1E)`; their expectations stay the same.

- [ ] **Step 3: Run them and see them fail**

Run: `./dev flutter test --concurrency=1 test/core/theme/palette_test.dart`
Expected: compile failure on the `background:` parameter and `Palettes.linux`.

- [ ] **Step 4: Implement**

Add the `background` parameter to `legibleAccent`, replacing `_macosBackground` inside `clears`. `macos` passes `_macosBackground`. Add three private `_linuxRamp` constants (or a `switch` returning one), plus `linux(desktop, accent)`. It fills `primary`, `primaryFocus` (lerp 15% toward black), `onPrimary` (`onColorFor`), `cardHover = surfaceVariant`, `shimmerBase = surface`, `shimmerHighlight = surfaceVariant` and `ambientTint: false`.

- [ ] **Step 5: Run the theme tests and see them pass**

Run: `./dev flutter test --concurrency=1 test/core/theme/`
Expected: all pass, including `theme_contrast_test.dart`.

- [ ] **Step 6: Commit**

`feat(player): add GNOME, KDE and elementary dark palettes`

---

### Task 4: The `linux` preset, the shared resolver and the label

**Files:**
- Modify: `player/lib/core/theme/theme_preset.dart`
- Modify: `player/lib/core/theme/theme_providers.dart` (`palette` provider; add `presetPalette`)
- Modify: `player/lib/presentation/widgets/theme_preset_picker.dart:62-90` (`_Swatch`)
- Modify: `player/lib/l10n/formatters.dart:282-287`
- Modify: `player/lib/l10n/app_en.arb`, `app_es.arb`, `app_pt.arb`, `app_pt_BR.arb` (next to `themePresetMacos`)
- Test: `player/test/core/theme/theme_providers_test.dart`, plus a preset test (in `palette_test.dart` where the existing `ThemePreset` tests live)

**Interfaces:**
- Consumes: `linuxDesktopProvider` (Task 1), `linuxAccentProvider` (Task 2), `Palettes.linux` (Task 3)
- Produces:
  - `ThemePreset.linux`
  - `MydiaPalette palette({Color systemAccent = Palettes.macosDefaultAccent, LinuxDesktop linuxDesktop = LinuxDesktop.other, Color? linuxAccent})`
  - `@Riverpod(keepAlive: true) MydiaPalette presetPalette(Ref ref, ThemePreset preset)`, giving `presetPaletteProvider(preset)`
  - l10n: `themePresetLinux(String desktop)` = `"System ({desktop})"` and `themePresetLinuxGeneric` = `"System"`
  - `String themePresetName(ThemePreset preset, {LinuxDesktop linuxDesktop = LinuxDesktop.other})` in `formatters.dart`

- [ ] **Step 1: Write the failing tests**

- `linux is offered only on native Linux`: `ThemePreset.linux.isAvailableOn(TargetPlatform.linux, isWeb: false)` is true; on `linux` with `isWeb: true`, and on `macOS`, `android` and `windows`, it is false. `ThemePreset.availableOn(TargetPlatform.macOS, isWeb: false)` does not contain `linux`.
- `Linux defaults to the linux preset`: `defaultFor(TargetPlatform.linux, isWeb: false) == ThemePreset.linux`; `defaultFor(TargetPlatform.android, isWeb: false) == projectionBooth`; `defaultFor(TargetPlatform.macOS, isWeb: false) == macos`.
- **Review Focus 5** `a stored linux elsewhere falls back`: `resolve('linux', TargetPlatform.macOS, isWeb: false) == macos`; `resolve('linux', TargetPlatform.android, isWeb: false) == projectionBooth`; `resolve('linux', TargetPlatform.linux, isWeb: true) == projectionBooth`.
- `a stored pick wins on Linux` (in `theme_providers_test.dart`, mirroring the existing macOS stored-pick test): stored `'slate'` resolves to `slate` on Linux.
- `palette follows the Linux accent`: a container with `themePresetSettingProvider` on `linux`, `linuxDesktopProvider` overridden to `kde` and `linuxAccentProvider` overridden to a fixed notifier returning `#FF00FF00`. Expect `palette.primary == Palettes.linux(LinuxDesktop.kde, const Color(0xFF00FF00)).primary`. Update the override so the palette changes.
- `presetPalette(macos) still follows the system accent`: the existing macOS provider test, pointed at `presetPaletteProvider(ThemePreset.macos)`.

- [ ] **Step 2: Run them and see them fail**

Run: `./dev flutter test --concurrency=1 test/core/theme/theme_providers_test.dart test/core/theme/palette_test.dart`
Expected: compile failure on `ThemePreset.linux`.

- [ ] **Step 3: Implement the preset and resolver**

Add `linux` last in `ThemePreset`, then `isAvailableOn`, `defaultFor` and the `palette(...)` branch. Add the `presetPalette` provider, which watches `systemAccentProvider` only for `macos` and the two Linux providers only for `linux`. Change `palette(Ref ref)` to `ref.watch(presetPaletteProvider(ref.watch(themePresetSettingProvider)))`. Change `_Swatch` to watch `presetPaletteProvider(preset)` and drop its `macos` branch and the `systemAccentProvider` import if it is now unused. Regenerate with `./dev flutter pub run build_runner build --delete-conflicting-outputs`.

- [ ] **Step 4: Add the label**

Add `themePresetLinux` with a `desktop` String placeholder (example `"GNOME"`) and `themePresetLinuxGeneric` to all four `.arb` files. The `@` description says that it names the colour theme that follows the Linux desktop's accent and greys, and that the placeholder is the desktop's proper name and is not translated. Translations: es `"Sistema ({desktop})"` / `"Sistema"`, pt and pt_BR `"Sistema ({desktop})"` / `"Sistema"`. In `formatters.dart`, the `linux` arm returns `linuxDesktop.displayName` mapped through `themePresetLinux`, or `themePresetLinuxGeneric` when it is null. Every `themePresetName` call site passes `ref.watch(linuxDesktopProvider)` (find them with `grep -rn themePresetName lib`). Regenerate with `./dev flutter gen-l10n`.

- [ ] **Step 5: Run the theme and picker tests, then analyze**

Run: `./dev flutter test --concurrency=1 test/core/theme/ test/presentation/widgets/ test/l10n/`
Expected: all pass. Then `./dev flutter analyze --fatal-infos`. Expected: "No issues found!"

- [ ] **Step 6: Commit**

`feat(player): offer a Linux native theme and default to it on Linux`

---

### Task 5: Whole-suite run and live check

**Files:** none unless a check fails.

- [ ] **Step 1: Run the full player suite**

Run: `./dev flutter test --concurrency=1`
Expected: "All tests passed!" with a count near the suite's usual size (about 7,600 or more). A materially lower count means files were skipped; see `player/docs/workflow.md`.

- [ ] **Step 2: Live check on GNOME**

Run `./dev player flatpak build && ./dev player flatpak install && ./dev player flatpak run` on a GNOME 47+ session. Expected: Settings, Appearance shows "System (GNOME)" selected on a fresh profile, and the accent matches GNOME's. Change the accent in GNOME Settings, Appearance; the player updates without a restart.

- [ ] **Step 3: Live check without a portal accent**

Run the native debug build (`./dev flutter run -d linux`) under a session whose portal lacks `accent-color`, or with `XDG_CURRENT_DESKTOP=KDE` and the portal stopped (`systemctl --user stop xdg-desktop-portal`). Expected: the app starts on the Breeze ramp with the lifted `#3DAEE9`, one `[LinuxAccent]` log line, and no exception. Restart the portal afterwards.

- [ ] **Step 4: Record results**

If a live check could not be run here (no KDE or elementary session available), say so in the PR description rather than claiming it.
