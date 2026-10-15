# The native iOS 26 tab bar

On an iPhone running iOS 26 the player replaces the Flutter dock with a real
`UITabBarController` tab bar (Liquid Glass), and the floating cast bar with
its bottom accessory. Flutter still draws every screen. Everywhere else
(older iOS, iPad, Android, desktop, web) `BottomNav` and the floating cast bar
are unchanged.

| Side | File | Job |
| --- | --- | --- |
| Swift | `ios/Runner/MydiaTabBarController.swift` | the window root: tab bar, accessory, inset reports, touch pass-through |
| Swift | `ios/Runner/NativeTabBarPlugin.swift` | owns the `mydia/native-tab-bar` channel and drives the controller |
| Swift | `ios/Runner/CastAccessoryView.swift` | the accessory's content view and its model |
| Swift | `ios/Runner/AppDelegate.swift` | `installNativeTabBar()`, the root swap |
| Dart | `lib/core/platform/native_tab_bar_support.dart` | `NativeTabBarSupport`, the once-at-startup probe |
| Dart | `lib/core/platform/native_tab_bar_channel.dart` | `NativeTabBarChannel`, `NativeTab`, `NativeAccessory`, the events |
| Dart | `lib/presentation/widgets/nav/native_tab_bar.dart` | `NativeTabBar`, the shell's `bottomNavigationBar` on this path |
| Dart | `lib/presentation/widgets/cast_bar/cast_bar_state.dart` | `castBarStateProvider` and `CastBarText`, shared by both cast surfaces |
| Dart | `lib/presentation/widgets/cast_bar/native_cast_accessory.dart` | `NativeCastAccessory`, mirrors the state into the accessory |
| Dart | `lib/presentation/widgets/cast_controls_sheet.dart` | the sheet an accessory tap opens |

All Swift that touches iOS 26 API is inside `#if compiler(>=6.2)` and
`@available(iOS 26.0, *)`, so an older Xcode still builds the app, just
without the bar.

## The fallback rule

`NativeTabBarSupport.supported` is true only when the native `isSupported`
call answers true. Native answers true only when the build used the iOS 26 SDK,
the device runs iOS 26 or later, it is an iPhone, and the tab controller was
actually installed. Anything else is false, and Dart then builds the Flutter
dock exactly as before: a missing plugin, a PlatformException, any other
error, or no answer within 2 seconds (each is logged as
`[NativeTabBar] ... using the Flutter dock`).

`initialize()` runs once inside the `inputCapabilities` startup step of
`_startApp` in `main.dart`, through `Future.wait` alongside
`InputCapabilities.initialize()`, and `supported` is read synchronously in
`build` afterwards (the same shape as `InputCapabilities`). `flutter test` never calls `initialize()`, so tests see
false unless they set `NativeTabBarSupport.debugOverride` (reset it in
`tearDown`).

## Root swap ordering

`installNativeTabBar()` replaces `window.rootViewController` with a
`MydiaTabBarController` that holds the `FlutterViewController` as a child. It
must stay the last step before `super.application(...)` in
`didFinishLaunching`: `FlutterAppDelegate` resolves `registrar(forPlugin:)`
through `window.rootViewController as? FlutterViewController`, and that cast
stops matching once the tab controller is the root. Every plugin registered
after the swap would get no registrar.

The Flutter view controller is added once as a child, pinned full screen
beneath the tab content, and never moved afterwards. Re-parenting it sends the
app lifecycle `inactive`, which pauses playback and raises the privacy blur.

Flutter, not the tab controller, owns the status bar, the home indicator,
orientation and the edge gestures (the immersive player changes all four). The
tab controller forwards each decision to the Flutter controller through the
matching `childFor...` and `supportedInterfaceOrientations` overrides.

If the root is not a `FlutterViewController` when the swap runs, the swap is
skipped and logged: `[NativeTabBar] root swap skipped: window or
FlutterViewController root missing`. `isSupported` then answers false and the
app runs on the Flutter dock.

## Touch pass-through

The tab controller's content must never take a touch from Flutter. Each tab
hosts a `PassThroughViewController` whose view returns nil from `hitTest`.
UIKit also wraps the selected tab's view in private container views that sit
above the Flutter view, and a container whose subviews all miss claims the
touch itself. `viewDidLayoutSubviews` therefore walks up from the selected
tab's view and turns `isUserInteractionEnabled` off on each container, stopping
at the root view or at any ancestor of the tab bar or the accessory, which must
stay interactive.

If touches stop reaching Flutter after an OS update, this walk is the first
place to look.

## The channel contract

Channel `mydia/native-tab-bar`. Dart calls native:

| Method | Arguments | Meaning |
| --- | --- | --- |
| `isSupported` | none | `true` only when the controller is installed; `false` otherwise |
| `setTabs` | list of `{id, title, symbol, badge?, enabled}` | replace the tabs; `symbol` is an SF Symbol name, an unknown one logs and shows `circle` |
| `select` | tab id | move the selection without emitting `tabSelected`; an unknown id logs `select: unknown tab id` |
| `setVisible` | bool | show or hide the bar (and with it the accessory), animated |
| `setAccessory` | `{title, subtitle?, artwork?, symbol?, playing?}` or null | set or remove the accessory; `playing` null hides the play/pause button |

Native calls Dart:

| Method | Arguments | Meaning |
| --- | --- | --- |
| `tabSelected` | tab id | the user tapped an enabled tab |
| `insetsChanged` | double | the bar plus the accessory plus the home indicator, in points; 0 while hidden |
| `accessoryTapped` | none | the summary area was tapped |
| `accessoryPlayPause` | none | the play/pause button was tapped |

Rules both sides keep:

- Dart drops a value equal to the last one it sent, so widgets call the setters
  on every build.
- Native refuses every tap (`shouldSelect` always returns false) and waits for
  `select`. Flutter's route is the only source of truth for the selection, so a
  tap the shell refuses (offline, say) never leaves the bar on the wrong tab.
  A disabled tab reports nothing.
- `insetsChanged(0)` is ignored by Dart. Zero means the bar is hidden (drawer
  open, or a route covers the shell), and reflowing the content behind the
  drawer would make every screen jump. Dart keeps the last real height.
- A native failure is logged and swallowed in Dart: the bar is chrome, never a
  reason to crash.

## Insets

`NativeTabBar` is the Scaffold's `bottomNavigationBar` where `BottomNav` would
be, and draws only a pointer-transparent box as tall as the native inset. Until
native reports one, the height is 83 plus the home indicator
(`NativeTabBar.fallbackBarHeight`, the Flutter dock's measured height), so the
first frame does not jump. With `Scaffold(extendBody: true)` the box is
published as the body's `padding.bottom`, which is what `DockInsets` reads, so
every screen clears the native bar with no per-screen change.

Native computes the inset from the selected tab's `safeAreaInsets.bottom`,
which already includes the bar, the accessory and the home indicator. The box
is also a bottom `ToastObstruction`, so toasts sit above the bar.

The bar is visible when all three hold (`AppShell.nativeBarVisible`):

- the shell's route is current on the root navigator (no page, dialog or
  sheet above it: not the immersive player),
- no popup is on the ShellRoute's own navigator, and
- the drawer is closed.

A native bar must not sit over a Flutter sheet. The second rule exists because
`showModalBottomSheet` defaults to `useRootNavigator: false` (and `showDialog`
does when asked), so called from a content screen they land on the shell
navigator, which leaves the shell's root route current. `ShellPopupObserver` (wired as the ShellRoute's
`observers`, read by `AppShell`) reports whether any `PopupRoute` is in that
navigator's stack. It only hides the native bar: it never feeds
`ReportedNativeBar`, so a popup does not bring the floating cast pill back
(only a page over the shell does, via `PageCoverObserver`). The unsupported
path never reads it.
`NativeTabBar.dispose` hides it, so leaving the mobile layout (rotation to a
sidebar width, sign-out) takes the bar with it. The bar starts hidden, so a
launch that never reaches the shell (login, startup errors) shows nothing.

The settings badge is `1` only while an update is waiting
(`settingsTabBadge`). The Flutter badge's always-lit connection dot has no
native equivalent and would be a permanent badge that means nothing.

## The accessory

`castBarStateProvider` (`cast_bar_state.dart`) is the one source for both
surfaces, and `CastBarText` holds the words, so the Flutter bar and the
accessory cannot drift. `AppShell` mounts `NativeCastAccessory` on the native
path. It draws nothing; it maps the state to a `NativeAccessory` and sends it,
and sends null when it is disposed.

| State | Title | Subtitle | Symbol | Play/pause |
| --- | --- | --- | --- | --- |
| none | (accessory removed) | | | |
| ambient | the title being watched | `Playing on <device>` | `tv` | none |
| offline | the device name | `Not connected` | `airplayvideo` | none |
| connecting | `Connecting to <device>…` | none | `airplayvideo` | none |
| stale | the media title, else the device | `Lost connection to <device>` | `airplayvideo` | none |
| idle | `Ready to play on <device>` | `Connected` | `airplayvideo.circle.fill` | none |
| playing | the media title, else the device | `Casting to <device>` | `airplayvideo` | shows play or pause |
| playing, syncing | as playing | `Reconnecting to <device>…` | `airplayvideo` | none |

Artwork is the media's image URL when there is one. The accessory shows the
symbol at once, swaps in the artwork if it loads, and keeps the symbol if it
fails (artwork is cached in memory by URL).

The accessory shows only while the bar is visible, so it follows the drawer,
the player and the shell route. While it is the cast bar, `CastBarLayer`
unmounts the floating `CastMiniController` (`DockExtents.nativeBar`, reported
by `ReportedNativeBar`), which also drops that bar's reported height, since
the native inset already includes the accessory.

The flag drops, and the floating bar comes back, only when a PAGE covers the
shell (a `PageRoute`: the immersive player, any go_router page pushed over
it). A popup route (a dialog, a modal bottom sheet, including the accessory's
own cast sheet) does not count: the native bar hides under it, but the
floating bar stays away, or it would paint over the sheet. Pages are told
from popups by `PageCoverObserver` (`lib/core/router/page_cover_observer.dart`),
a `NavigatorObserver` on the root `GoRouter` that tracks the route stack;
`AppShell.nativeBarReported` combines it with the native flag.

The accessory has room for a title and play/pause only. A tap anywhere but
play/pause opens `showCastControlsSheet` on the root navigator, a bottom sheet
hosting the same `CastMiniController`, so every control (scrubber, skip,
subtitles, stop, pull, reconnect) behaves as it does in the floating bar. The
sheet passes `reportsExtent: false`: it is not floating over the screens, so
it must not report a height into `DockExtents` and pad them.

Two details of the sheet worth knowing:

- The native accessory sits above Flutter's modal barrier, so it can be tapped
  while the sheet is up. `NativeCastAccessory` ignores taps while its sheet is
  open, so a second tap never stacks a second sheet.
- When casting ends (state becomes null) the sheet removes its own route
  (`Navigator.removeRoute`), not the top route. A confirm dialog from the
  controller may be open above the sheet and must not be popped instead.

Play/pause calls `toggleCastPlayback`, shared with the floating bar. It does
nothing while the session is syncing, because the play state on screen may be
minutes old and a toggle could go the wrong way.

## Embed mode

When the player is embedded in Mydia, the bar leads with a `Mydia` back item
(id `mydia-back`, symbol `chevron.backward`). Tapping it calls
`navigateToMydiaApp` instead of navigating. It stays enabled offline.

## Offline

Offline, every tab but Downloads is disabled (dimmed, and native sends
nothing for a tap), as on `BottomNav`. The shell's `offlineRouteAllowed` rule
still applies to whatever Dart is asked to navigate to.

## Adding a tab or a symbol

A bar entry's SF Symbol is one line in `_tabSymbols` in `native_tab_bar.dart`.
An entry the map lacks gets `circle`, and an unknown symbol name logs
`[NativeTabBar] unknown SF Symbol <name>, using circle` on the native side.

## Spike results

Simulator, iOS 26.2 (iPhone 17 Pro, simulator `mydia-ios26`), from the first
spike build (a hard-coded bar and accessory, before the Dart side existed):

- The native glass bar renders over the Flutter view with five tabs: Home
  (selected, with the lens), Movies, Shows, Downloads, and Settings.
- The Settings badge shows a red `1`.
- The accessory renders ("Night Harbor", "Casting to Lantern Room", with a
  pause button) above the bar.
- The bar plus accessory inset logged as `139.0` points on that device, larger
  than the home indicator alone, which is the number Flutter has to clear.
- No `unknown SF Symbol` lines.

Simulator smoke of the shipped build, 2026-10-14 (debug build, signed out):
the debug build installed and launched on the same simulator. Signed out, the
app shows the Flutter "Add a server" screen with no native bar and no
accessory, and the Flutter UI is unchanged, which is the intended behavior
before the shell is reached (the bar starts hidden). The simulator log holds
no `[NativeTabBar]` lines (no probe failure, no skipped root swap).

Not verifiable on the simulator without a signed-in session and interaction:
tab taps, touch pass-through, scrolling, text entry, the accessory states, the
sheet, the drawer, the player, rotation, VoiceOver.

### Device gate: pending

Nothing below has been run on a physical iOS 26 iPhone. Fill this in after the
TestFlight run, one line per item with the date, app version, iPhone model and
iOS version. Do not record a line that was not observed.

From the spike (the lifecycle and plugin checks the simulator cannot show):

- [ ] Backgrounding and returning does not pause playback or raise the privacy
  blur spuriously (the Flutter view controller is never re-parented).
- [ ] Plugins that present UIKit (share sheet, pickers) work with the tab
  controller as root.
- [ ] AirPlay route picker and the audio session still work.
- [ ] Rotation, status bar and home indicator follow Flutter.
- [ ] Touches reach Flutter everywhere outside the bar and accessory (taps,
  scrolling, text entry).

From the shipped build:

- [ ] Every spike item above still passes.
- [ ] Real navigation across every tab, including a deep page then a tab tap
  back to its root.
- [ ] The Settings badge shows `1` while an update is waiting.
- [ ] Offline: every tab but Downloads is dimmed and does nothing.
- [ ] The drawer hides the bar and the accessory; closing brings both back;
  content does not reflow.
- [ ] The player hides the bar; leaving it brings the bar back.
- [ ] Every accessory state while casting: ambient, offline, connecting,
  stale, idle, playing, paused, and syncing (background the app for a minute,
  then return).
- [ ] Accessory play/pause works; a tap opens the sheet; stopping from the
  sheet closes it.
- [ ] VoiceOver reads each tab, the badge, the accessory summary and its
  play/pause button.
- [ ] Open the cast sheet from the accessory: no second cast pill appears.
- [ ] Open a dialog from a shell screen: the floating cast pill does not
  appear.
- [ ] Close the drawer: screens do not jump.
- [ ] Scroll in the middle of the screen right after a tab switch.
- [ ] Status-bar tap scrolls the screen to the top (unverified after the root
  swap, see Known limits).
- [ ] Rotation: landscape switches to the sidebar (bar gone); portrait brings
  the bar back on the right tab.
- [ ] Embed mode (if testable): the `Mydia` back item leads and works.
- [ ] No `unknown SF Symbol` or `unknown tab id` lines in the device log.

## Known limits

- Status-bar tap scroll-to-top after the root swap is unverified:
  `FlutterAppDelegate` forwards some behavior only when the root is a
  `FlutterViewController`, and the root is now the tab controller. Check on
  device.
- Cast artwork in the native accessory is fetched by `URLSession` and is
  subject to App Transport Security. Plain-http artwork fails to load and the
  accessory keeps the state symbol.

## Adding a Swift file to the Runner

`ios/Runner.xcodeproj/project.pbxproj` is edited by hand, and each new Swift
file needs four entries, with one unique ID per entry (the bar's files use the
`7AB0C0DE...` prefix, in pairs):

1. a `PBXBuildFile` entry (`<id> /* X.swift in Sources */`, pointing at the
   file reference),
2. a `PBXFileReference` entry (`<id> /* X.swift */`, path `X.swift`),
3. the file reference in the `Runner` group's `children`,
4. the build file in the Runner target's `Sources` build phase `files`.

Building with a newer Flutter may migrate the project to Swift Package
Manager and rewrite `project.pbxproj`, `Podfile.lock` and the Runner scheme.
Revert that churn; do not commit it with a feature change.
