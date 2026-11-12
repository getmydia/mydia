# Player: Linux native theme

Date: 2026-11-07
Status: approved for planning

## Goal

On the Linux desktop player, offer a theme preset that looks at home on the
viewer's desktop: the dark window greys of GNOME (Adwaita), KDE Plasma
(Breeze) or elementary OS, with the accent colour the viewer chose in their
desktop settings, following it live when they change it.

It is the Linux counterpart of the existing `macos` preset
(`player/lib/core/theme/system_accent.dart`, `Palettes.macos`), which pairs
fixed macOS window greys with the live system accent.

## Decisions

- **Accent plus per-desktop greys.** The accent is read live from the
  desktop. The surface ramp is a fixed dark ramp matched to the detected
  desktop. Custom GTK themes and KDE colour schemes are not parsed.
- **Default on Linux.** `ThemePreset.defaultFor` returns the new preset on
  native Linux. A stored pick still wins, so anyone who already chose a
  preset keeps it.
- **Always dark.** Every preset is dark today; the desktop's light/dark
  preference (`color-scheme`) is not read.
- **One preset, desktop detected.** A single `ThemePreset.linux`, not one
  preset per desktop. Its label names the detected desktop.

## Source of the accent: the XDG Settings portal

The accent comes from `org.freedesktop.portal.Settings` on the session bus
(`org.freedesktop.portal.Desktop`, `/org/freedesktop/portal/desktop`),
namespace `org.freedesktop.appearance`, key `accent-color`. GNOME 47+,
KDE Plasma 6 and elementary OS publish it.

Why the portal and not per-desktop config: it is one code path for all three
desktops, it works identically in the Flatpak sandbox and in a native
install with no new `finish-args`, and it uses the `dbus` package already in
`pubspec.yaml` (used by `lib/core/update/flatpak_portal.dart` and the MPRIS
session). Reading gsettings or `kdeglobals` directly would need three parsers
and sandbox holes. Reading GTK in the C++ runner would not cover KDE.

The value is `(ddd)`: sRGB red, green, blue as doubles in [0, 1]. Per the
portal spec, any component outside [0, 1] means "no accent set". The value
arrives wrapped in a variant (twice, through the deprecated `Read`).

## Components

### `LinuxDesktop` (new, `lib/core/theme/linux_desktop.dart`)

```dart
enum LinuxDesktop { gnome, kde, elementary, other }
```

`LinuxDesktop.parse(String? xdgCurrentDesktop)` splits the value on `:` and
matches entries case-insensitively, first match wins:

| Entry | Result |
| --- | --- |
| `Pantheon` | `elementary` |
| `KDE` | `kde` |
| `GNOME` (also inside `ubuntu:GNOME`, `GNOME-Classic`) | `gnome` |
| anything else, or unset | `other` |

`Pantheon` is checked before `GNOME` because elementary sessions can list
both. `other` (XFCE, Cinnamon, Sway, ...) uses the Adwaita ramp and accent,
since most of those desktops run GTK apps styled close to it.

Each value carries its stock accent, used when the portal reports none:

| Desktop | Stock accent | Source |
| --- | --- | --- |
| gnome, other | `#3584E4` | libadwaita accent blue |
| kde | `#3DAEE9` | Breeze highlight |
| elementary | `#3689E6` | elementary Blueberry 500 |

`linuxDesktopProvider` reads `Platform.environment['XDG_CURRENT_DESKTOP']`
once. Flatpak passes the variable through to the sandbox.

### `LinuxAccent` (new, `lib/core/theme/linux_accent.dart`)

`linuxAccentProvider`, a hand-written `NotifierProvider<LinuxAccent, Color?>`
(riverpod_generator cannot generate a `Color` state, see `SystemAccent`).
`null` means the desktop reports no accent.

- Off native Linux, or in tests without an override, `build` returns `null`
  and touches no bus. A `@visibleForTesting static bool? debugIsNativeLinux`
  forces the platform check, as `SystemAccent.debugIsNativeMacOS` does.
- On Linux it subscribes to `SettingChanged` filtered to the appearance
  namespace and `accent-color`, then calls `ReadOne`. If `ReadOne` fails with
  `UnknownMethod` (portal version 1), it retries with `Read`. The first
  answer to land sets the state; a signal that arrives before the read
  answers is not overwritten by the read.
- Decoding lives in a pure function,
  `Color? decodePortalAccent(DBusValue value)`, which unwraps nested
  variants, expects a three-double struct, returns `null` for any component
  outside [0, 1] or any other shape, and rounds each component to 8 bits.
- Every D-Bus failure (no session bus, no portal, `NotFound` for the key,
  wrong type) is logged with `debugPrint` once and leaves the state `null`.
  Nothing is surfaced to the viewer: the stock accent is a correct theme.
- `ref.onDispose` cancels the subscription and closes the `DBusClient`.

### `Palettes.linux` (in `palette.dart`)

`static MydiaPalette linux(LinuxDesktop desktop, Color? accent)` builds the
palette from the desktop's ramp and `accent ?? desktop.stockAccent`, passed
through the accent contrast lift.

The ramps, each in rising luminance as `palette_test` already asserts for
every palette. Anchors are the desktop's own dark colours; the steps between
them are interpolated to fill the seven-step ramp.

| Field | Adwaita (gnome, other) | Breeze (kde) | elementary |
| --- | --- | --- | --- |
| background | `#1D1D20` (view) | `#141618` (view) | `#1A1A1A` (level 4) |
| surfaceDim | `#202023` | `#1A1C1E` | `#202020` (level 3) |
| surfaceLow | `#222226` (window) | `#202326` (window) | `#262626` (bg, level 2) |
| surface | `#28282C` (secondary sidebar) | `#25282B` | `#2C2C2C` (base, level 1) |
| surfaceHigh | `#2E2E32` (headerbar) | `#292C30` (button) | `#333333` (level 0) |
| surfaceVariant | `#36363A` (dialog) | `#31363B` | `#3A3A3A` |
| surfaceBright | `#3E3E43` | `#3B4045` | `#404040` (BLACK-400) |
| textPrimary | `#FFFFFF` | `#FCFCFC` | `#FFFFFF` |
| textSecondary | `#B4B4B6` | `#A1A9B1` (inactive) | `#ABACAE` (SILVER-500) |
| textDisabled | `#8E8E91` | `#7F8C8D` | `#8A8A8A` |
| divider | `#2A2A2E` | `#25282B` | `#2B2B2B` |
| border | `#3A3A3E` | `#3F444A` | `#474747` |

Anchors were checked against upstream on 2026-11-07: libadwaita
`src/stylesheet/_colors.scss` (dark block), Breeze `colors/BreezeDark.colors`
(View, Window, Button) and granite `lib/Styles/Common/_lighting.scss` dark
`--bg-level-*` over the `BLACK-*` palette. elementary's levels are oklab
mixes of `#333`, `#262626` and `#1A1A1A`; levels 1 and 3 are rounded to the
sRGB midpoints. `palette_test` pins these values, and `theme_contrast_test`
runs every desktop with its stock accent and a set of sample accents through
the WCAG floors. The remaining fields reuse ramp steps: `cardHover` is
`surfaceVariant`, `shimmerBase` is `surface`, `shimmerHighlight` is
`surfaceVariant`. `primaryFocus` is the accent darkened 15%, `onPrimary` is
`onColorFor(accent)`, and `ambientTint` is `false`: the desktop's ground is
the point of the preset.

**Contrast lift.** `legibleAccent(Color)` is generalised to
`legibleAccent(Color accent, {required Color background})`, checking 4.55:1
against the given background and the OSD worst case. `Palettes.macos` passes
`_macosBackground`; `Palettes.linux` passes the ramp's `background`. Breeze's
`#3DAEE9` and Adwaita's `#3584E4` are lifted where they fall short on the
OSD fill, exactly as macOS system blue is.

### `ThemePreset` (in `theme_preset.dart`)

- New value `linux`, appended last so stored names and ordering of existing
  values are unchanged.
- `isAvailableOn`: `macos` only on native macOS, `linux` only on native Linux
  (`!isWeb && platform == TargetPlatform.linux`).
- `defaultFor`: `macos` where available, else `linux` where available, else
  `projectionBooth`.
- `palette(...)` gains `LinuxDesktop desktop` and `Color? linuxAccent`
  parameters for the `linux` branch.

### One resolver for system-driven palettes

Today the `palette` provider and the picker's `_Swatch` both special-case
`macos` to watch `systemAccentProvider`. Adding `linux` would duplicate that a
second time. Both move to one family provider in `theme_providers.dart`,
`presetPaletteProvider(ThemePreset preset)`, which watches
`systemAccentProvider` only for `macos` and `linuxDesktopProvider` +
`linuxAccentProvider` only for `linux`. The `palette` provider becomes
`ref.watch(presetPaletteProvider(selectedPreset))`, and `_Swatch` watches
`presetPaletteProvider(preset)`, so the picker swatch for `linux` shows the
live desktop accent.

### Label

`themePresetLinux` in `app_en.arb`, `app_es.arb`, `app_pt.arb`,
`app_pt_BR.arb`, with a `{desktop}` placeholder: "System ({desktop})". The
desktop names (`GNOME`, `KDE Plasma`, `elementary OS`) are proper nouns and
are not translated. For `other` the label is a separate key,
`themePresetLinuxGeneric`, "System". `formatters.dart` maps the preset to the
label.

## Data flow

```
XDG_CURRENT_DESKTOP ──► linuxDesktopProvider ──┐
                                                ├─► presetPaletteProvider(linux) ─► palette ─► AppTheme
portal ReadOne / SettingChanged ─► linuxAccentProvider ┘                       └─► picker swatch
```

A desktop accent change emits `SettingChanged`, the notifier updates, and the
theme rebuilds through the existing `MydiaPalette.lerp` animation.

## Error handling

| Situation | Result |
| --- | --- |
| No session bus, no portal, portal too old for the key | stock accent for the desktop, logged once |
| Key present but "unset" (component outside [0, 1]) | stock accent |
| Malformed value | stock accent, logged |
| Portal appears or the viewer sets an accent later | picked up by `SettingChanged` if the subscription was established; otherwise next launch |
| Unknown desktop | Adwaita ramp and accent, label "System" |
| Stored `linux` preset opened on another platform (synced settings, web) | `ThemePreset.resolve` falls back to that platform's default, as it does for `macos` |

## Testing

- `linux_desktop_test.dart`: `parse` table, including `ubuntu:GNOME`,
  `Pantheon:GNOME`, `KDE`, mixed case, empty and null.
- `linux_accent_test.dart`: `decodePortalAccent` for a plain struct, a
  doubly wrapped variant (`Read`), out-of-range components, wrong arity and
  wrong types. The notifier with `debugIsNativeLinux = false` returns `null`
  and opens no bus; with an injected fake portal client it takes the read
  value, then a signal value, and a late read does not overwrite a signal.
  The client is injected through a small `PortalSettingsClient` seam so tests
  need no real bus.
- `palette_test.dart`: each Linux ramp rises in luminance; text and accent
  clear the existing contrast floors; `legibleAccent` keeps already-legible
  accents and lifts Breeze and Adwaita blues where needed.
- `theme_preset` / `theme_providers_test.dart`: `linux` offered only on
  native Linux; `defaultFor(linux)` is `linux`; a stored pick wins; the
  `palette` provider follows an overridden `linuxAccentProvider`.
- Existing `macos` tests keep passing through the shared resolver.
- Manual check on the local Flatpak (`./dev player flatpak build && run`)
  under GNOME and KDE: accent matches, and changing it in system settings
  updates the player live.

## Out of scope

- Light themes and following `color-scheme`.
- Parsing custom GTK themes or KDE colour schemes.
- Window decorations, header bar, or font changes.
- Any change to Liquid Glass or `depth_tokens.dart`.
