# The native iOS 26 tab bar, iPad sidebar and macOS sidebar

On an iPhone running iOS 26 the player replaces the Flutter dock with a real
`UITabBarController` tab bar (Liquid Glass), and the floating cast bar with
its bottom accessory. On an iPad running iPadOS 26 the same controller runs
in `.tabSidebar` mode and replaces the Flutter rail with a native sidebar (see
[iPad sidebar](#ipad-sidebar)). On macOS an AppKit split view puts a native
source-list sidebar beside the Flutter pane, served by the same channel (see
[macOS sidebar](#macos-sidebar)). Flutter still draws every screen. Everywhere
else (older iOS, Android, Windows, Linux, web) `BottomNav`, the rail and the
floating cast bar are unchanged.

| Side | File | Job |
| --- | --- | --- |
| Swift | `ios/Runner/MydiaRootViewController.swift` | the window root: holds Flutter and the tab controller, routes touches |
| Swift | `ios/Runner/MydiaTabBarController.swift` | the tab bar, the accessory, inset reports, `hitTestBar` |
| Swift | `ios/Runner/NativeTabBarPlugin.swift` | owns the `mydia/native-tab-bar` channel and drives the controller |
| Swift | `ios/Runner/CastAccessoryView.swift` | the accessory's content view and its model |
| Swift | `ios/Runner/AppDelegate.swift` | creates `NativeTabBarPlugin` when the implicit engine starts |
| Swift | `ios/Runner/SceneDelegate.swift` | `installNativeTabBar()`, the root swap |
| Dart | `lib/core/platform/native_tab_bar_support.dart` | `NativeTabBarSupport`, the once-at-startup probe |
| Dart | `lib/core/platform/native_tab_bar_channel.dart` | `NativeTabBarChannel`, `NativeTab`, `NativeAccessory`, the events |
| Dart | `lib/presentation/widgets/nav/native_tab_bar.dart` | `NativeTabBar`, the shell's `bottomNavigationBar` on this path |
| Dart | `lib/core/platform/native_sidebar_state.dart` | `nativeSidebarRegularProvider` and `nativeSidebarInsetsProvider` (iPad) |
| Dart | `lib/presentation/widgets/nav/native_sidebar.dart` | `nativeSidebarFor`, the iPad payload built from the shell's rows |
| Dart | `lib/presentation/widgets/nav/native_sidebar_host.dart` | `NativeSidebarHost`, sends the payload and handles taps (iPad) |
| Dart | `lib/presentation/widgets/cast_bar/cast_bar_state.dart` | `castBarStateProvider` and `CastBarText`, shared by both cast surfaces |
| Dart | `lib/presentation/widgets/cast_bar/native_cast_accessory.dart` | `NativeCastAccessory`, mirrors the state into the accessory |
| Dart | `lib/presentation/widgets/cast_controls_sheet.dart` | the sheet an accessory tap opens |

All Swift that touches iOS 26 API is inside `#if compiler(>=6.2)` and
`@available(iOS 26.0, *)`, so an older Xcode still builds the app, just
without the bar.

## The fallback rule

`NativeTabBarSupport.mode` comes from one native `mode` call at startup:
`bar` on an iPhone, `sidebar` on an iPad, `none` otherwise. Native answers
`bar` or `sidebar` only when the build used the iOS 26 SDK, the device runs
iOS 26 or later, and the tab controller was actually installed; anything else
answers `none` (the plugin is created on every iOS version, so an older
device still answers). `supported` is `mode != none`. Dart treats a missing
plugin, a PlatformException, any other error, or no answer within 2 seconds as
`none` and builds the Flutter dock and rail exactly as before (each is logged
as `[NativeTabBar] ... using the Flutter dock`). `isSupported` is still
answered for older callers.

`initialize()` runs once inside the `inputCapabilities` startup step of
`_startApp` in `main.dart`, through `Future.wait` alongside
`InputCapabilities.initialize()`, and `supported` is read synchronously in
`build` afterwards (the same shape as `InputCapabilities`). `flutter test` never calls `initialize()`, so tests see
`none` unless they set `NativeTabBarSupport.debugOverride` (the bar) or
`debugOverrideMode` (any mode); reset both in `tearDown`.

On an iPhone (`mode == bar`) the bar stays in landscape too.
`Breakpoints.showsRail` answers false in `bar` mode whatever the width, so
`AppShell` keeps its mobile branch and every screen that reads the same
predicate (`DockInsets.bottomOf`, the title bars, the source picker) keeps its
phone layout with it. Width-based content density (`Breakpoints.isMobile`,
`getHorizontalPadding`) is unaffected, so landscape grids still use the width.

## Root swap ordering

The app uses the UIScene lifecycle. Built against the iOS 27 SDK, an app
without a scene manifest traps inside UIKit at launch
(`_UIApplicationEvaluateRuntimeIssueForNoSceneLifecycleAdoption`), before
Flutter draws anything: the device shows a blank screen.

Two callbacks run in this order at launch:

1. `AppDelegate.didInitializeImplicitFlutterEngine` runs when the storyboard's
   `FlutterViewController` creates its engine. It registers every plugin
   through the engine bridge's `pluginRegistry` and creates
   `NativeTabBarPlugin`. The registry belongs to the engine, so registration
   no longer depends on the window root and has no ordering constraint
   against the swap.
2. `SceneDelegate.scene(_:willConnectTo:options:)` calls `super` first, then
   `installNativeTabBar()`, which replaces `window.rootViewController` with a
   `MydiaRootViewController`.

## The container root

`MydiaRootViewController` is a plain `UIViewController` with two children,
both full screen: the `FlutterViewController` at the bottom and
`MydiaTabBarController` above it, with a clear background.

The Flutter view must never be a subview of the tab controller's view.
`UITabBarController` on iOS 26 and later owns its view's subviews and drops
any it did not add: an earlier revision inserted the Flutter view there, and
on device it ended up with no superview at all. Home showed a stale frame that
took no touches, the tab controller's opaque black view showed through on the
first tab change, and Dart stopped answering `select` once Flutter left the
window. A plain container leaves its subviews alone and forwards appearance
calls to Flutter unchanged.

The Flutter view controller is added once and never moved afterwards.
Re-parenting it sends the app lifecycle `inactive`, which pauses playback and
raises the privacy blur.

Flutter, not the tab controller, owns the status bar, the home indicator,
orientation and the edge gestures (the immersive player changes all four). The
root forwards each decision to the Flutter controller through the matching
`childFor...` and `supportedInterfaceOrientations` overrides.

If the root is not a `FlutterViewController` when the swap runs, the swap is
skipped and logged: `[NativeTabBar] root swap skipped: window or
FlutterViewController root missing`. If the engine callback has not created
the plugin yet, it logs `[NativeTabBar] root swap skipped: plugin not
registered`. `isSupported` then answers false and the
app runs on the Flutter dock.

## Touch routing

The root's view (`RootTouchView`) decides every hit test itself. It asks
`MydiaTabBarController.hitTestBar`, which runs the tab controller view's
normal `hitTest` and keeps the result only when it lies inside the tab bar or
the accessory's host. Anything else, and every point while the bar is hidden,
goes to `flutterView.hitTest`. UIKit's private tab containers cover the whole
screen and would claim touches meant for Flutter, so the rule never trusts
them.

The accessory's host is the outermost wrapper of `CastAccessoryView` that is
still shorter than the screen (its glass capsule), so a tap on the capsule's
padding counts. Each tab still hosts a `PassThroughViewController` whose view
returns nil from `hitTest`.

If touches stop reaching Flutter, or the bar stops taking them, after an OS
update, `hitTestBar` and `accessoryHost()` are the first places to look.

## The channel contract

Channel `mydia/native-tab-bar`. Dart calls native:

| Method | Arguments | Meaning |
| --- | --- | --- |
| `mode` | none | `bar` (iPhone), `sidebar` (iPad) or `none`; the startup probe |
| `isSupported` | none | `true` only when the controller is installed; `false` otherwise |
| `layout` | none | iPad: `{sidebar: bool}`, true at regular width |
| `setSidebar` | `{sections: [{id, title?, items}]}` | iPad, regular width: replace the sidebar (see [iPad sidebar](#ipad-sidebar)) |
| `setTabs` | list of `{id, title, symbol, badge?, enabled}` | replace the tabs; `symbol` is an SF Symbol name, an unknown one logs and shows `circle` |
| `select` | tab id, or null | move the selection without emitting `tabSelected`; an unknown id logs `select: unknown tab id`. Null clears it on an iPad (the iPhone ignores it) |
| `setVisible` | bool | show or hide the bar (and with it the accessory), animated |
| `setAccessory` | `{title, subtitle?, artwork?, symbol?, playing?}` or null | set or remove the accessory; `playing` null hides the play/pause button |

Native calls Dart:

| Method | Arguments | Meaning |
| --- | --- | --- |
| `tabSelected` | tab id | the user tapped an enabled tab |
| `insetsChanged` | double (iPhone), `{top, leading, bottom}` (iPad) | iPhone: the bar plus the accessory plus the home indicator, in points; 0 while hidden. iPad: see [iPad sidebar](#ipad-sidebar) |
| `layoutChanged` | `{sidebar: bool}` | iPad: the width class changed |
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

## iPad sidebar

On an iPad (`mode == sidebar`) `MydiaTabBarController` runs in `.tabSidebar`
mode through the `UITab` API. It is the same controller, plugin, channel and
container root as the iPhone; only the payload and the hit-test rule differ.

### Width class

Native reports the horizontal size class as `layoutChanged {sidebar}` and
answers `layout` once on request. `nativeSidebarRegularProvider` holds it,
starting at true (a full-screen iPad is regular, so the first frame shows the
sidebar). `AppShell.showsSidebarLayout` picks the layout: regular width
takes the rail branch with `NativeSidebarHost` in the rail's place, compact
width (Slide Over, a narrow Split View or window) takes the mobile branch, and
Dart sends the phone's `setTabs` payload, which iPadOS shows as a bottom tab
bar. At compact width every phone tab is placed in the bar. Going back to
regular width sends `setSidebar` again, and the selection follows the route.

### The `setSidebar` contract

`nativeSidebarFor` builds the payload from `sourceNavEntriesProvider`, the
same list, in the same order, that the Flutter `SidebarContent` renders.
`native_sidebar_parity_test.dart` pins that, so the native sidebar can never
show a different list from the Flutter one.

Each section is `{id, title?, items}`, and each item is `{id, title, symbol,
badge?, enabled, kind, inTabBar}`. Native applies two rules:

- **An untitled section's items are top-level tabs; a titled one is a
  group.** iPadOS lists every top-level tab above every group, so the order
  is: the leading rows (Mydia back, the current server's header, Search),
  the source's rows and New filter, then Edit sidebar, Downloads and
  Settings, and below them the titled `Servers` group on All servers. A
  group is `.sidebarOnly` and never reorders. An untitled group would draw a
  bare collapse chevron, which is why nothing is grouped without a title.
- **Placement.** Search is `.pinned`. `inTabBar` rows are `.fixed`: Dart sets
  it for Search and the first three rows of `bottomNavEntries` (Home, Movies,
  Shows), which iPadOS shows in the floating tab bar while the sidebar is
  hidden. Every other row is `.sidebarOnly`. Past about four tabs iPadOS pages
  that bar behind an arrow, which is why Downloads and Settings stay a toggle
  away. With nothing left to customize, UIKit drops its own Edit button; the
  sidebar's arrangement is the app's, edited through its own Edit sidebar row.

`kind: action` rows are not destinations. `NativeSidebarHost` handles them
when they arrive as `tabSelected`: `action:source-header` opens the Flutter
`SourcePicker` popover, `action:new-filter` the filter editor,
`action:edit-sidebar` the edit sheet, `mydia-back` returns to Mydia, and
`server-<id>` switches to that server. Like the bar, native refuses every tap
(`shouldSelectTab` returns false, a disabled row reports nothing) and waits
for `select`. A route no row matches sends `select(null)`, which clears the
highlight, as the Flutter sidebar shows none.

### Editing

Edit sidebar opens the Flutter edit sheet over the shell. The native sidebar
hides while the sheet is up (it is a popup on the shell navigator), and Done
writes the layout, which rebuilds the payload. A reorder shows in the native
sidebar as soon as the sheet closes. Tapping the scrim dismisses the sheet
without touching the page underneath.

### Insets and visibility

On an iPad `insetsChanged` sends `{top, leading, bottom}`, measured from the
tab content UIKit has on screen. That is not always the selected tab's own
controller: after `setSidebar` swaps in new tabs, or with no tab selected,
the selected one's view sits outside the window, so `visibleContent()` falls
back to the `PassThroughView` that is in the window.

- `top` is the content's safe-area top: the status bar plus the floating tab
  bar while the sidebar is hidden.
- `leading` is where the content starts: the sidebar's width while it is
  docked beside the content, and 0 while it floats over it.
- `bottom` is the home indicator.

`nativeSidebarInsetsProvider` keeps the last non-zero report (zero means the
chrome is hidden, as on the iPhone). `AppShell.nativeSidebarContentLeft` turns
`leading` into the content column's inset (minus the safe area that
`railLayers` adds back, plus the rail gap), and `AppShell._clearNativeTop`
raises the content's top padding to `top`, so every screen's title row
clears the floating bar the way it clears the status bar.

Visibility uses `view.alpha` rather than hiding the sidebar, so the
user's own shown/hidden choice survives a sheet or the player. The rule is
`AppShell.nativeBarVisible`, as on the iPhone.

### Touch routing on iPad

`hitTestBar` returns nil while the chrome is hidden. Otherwise
`sidebarHit` keeps the normal hit-test result unless it is one of UIKit's
full-screen containers or a `PassThroughView`, both of which go to Flutter.
The one exception: while the sidebar floats over the content (portrait), a
full-screen container is UIKit's, so a tap beside the sidebar dismisses it
as everywhere on iPadOS rather than reaching the Flutter screen dimmed
underneath.

### Spike results (iPad)

2026-10-16, simulator, iPad Pro 11-inch (M5), iPadOS 26, debug build against
a dev server:

- Portrait: the sidebar overlays the content and dims it. Insets read
  `top 32, leading 0, bottom 20` while it shows and `top 96, leading 0,
  bottom 20` while it is hidden (the floating bar). Content does not move.
  A tap beside the sidebar dismisses it.
- Landscape: the sidebar docks beside the content. Insets read `top 32,
  leading 280, bottom 20`, and the content starts at x=304. Hiding it gives
  `top 96, leading 0` and the content starts at x=24, below the bar.
- The toggle, every sidebar row and the floating bar's tabs take taps, and
  each row selects itself. Text entry works straight after a sidebar tap.
- Edit sidebar: a reorder shows in the native sidebar after Done; Reset
  restores it; a scrim tap dismisses the sheet. New filter opens the editor.
- The header row opens the source picker anchored at the sidebar's trailing
  edge in both orientations; the native sidebar fades out while it is open.
- Shrinking the window to compact width switches to the bottom tab bar with
  the phone's five entries; growing it back restores the sidebar on the same
  row.
- No `unknown SF Symbol` or `unknown tab id` lines.

## macOS sidebar

The macOS window's content is a `MydiaSplitViewController`: a sidebar
`NSSplitViewItem` holding `MydiaSidebarViewController` (a source-list
`NSOutlineView`) and a content item holding the `FlutterViewController`.

| File | Job |
| --- | --- |
| `macos/Runner/MydiaSplitViewController.swift` | the two panes, collapse on `setVisible`, the viewer's collapsed state |
| `macos/Runner/MydiaSidebarViewController.swift` | the outline view and the `setSidebar` payload model |
| `macos/Runner/NativeTabBarPlugin.swift` | owns `mydia/native-tab-bar` on macOS, measures `chromeLeading` |
| `macos/Runner/MainFlutterWindow.swift` | builds the split view, the toolbar, the title band rule |

The Flutter controller is added to the split view once in
`MainFlutterWindow.awakeFromNib` and never re-parented, for the same reason
the iOS container root exists: moving the engine's view between controllers
is what broke touches and rendering on iPhone. `contentViewController` is the
split view, so code that needs the Flutter controller (the Sparkle and
window chrome channels in `AppDelegate`) reaches it through
`MainFlutterWindow.flutterViewController`.

### Channel differences

Same method names and payloads as iOS, with these differences:

- `mode` always answers `"sidebar"` and `layout` always `{"sidebar": true}`.
  The pane never turns into a bar, so `layoutChanged` is never sent.
- `setTabs` and `setAccessory` are ignored (logged once each).
- `setSidebar` follows the iPad rule: untitled sections become top-level
  rows, titled ones (Servers) become groups.
- Dart owns selection. A click or an arrow key reports `tabSelected` and
  leaves the highlight alone; only `select` moves it.
- `setVisible(false)` collapses the sidebar for a page that covers the shell
  (the player). `setVisible(true)` restores whatever the viewer had, so a
  sidebar the viewer collapsed with the toggle stays collapsed afterwards.
  Dialogs, sheets and the source picker do not hide the pane: it is a
  separate pane, not an overlay.
- `insetsChanged` carries a `chromeLeading` key: how much of the Flutter
  pane's title band, from its leading edge, the window chrome covers. While
  the sidebar shows, the traffic lights and the toggle sit over the sidebar
  and it is 0. While it is collapsed, it is the trailing edge of the lights
  and the toggle minus the pane's leading edge, plus the 9pt gap
  `kMacTrafficLightsWidth` keeps. Measured at 132 on macOS 27. It is 0 in
  fullscreen. It is measured on every frame change of the Flutter view,
  because the collapse callback fires before the animated pane has moved.
  The system toggle item has no public `view`, so the plugin finds the
  title-bar control whose action is `toggleSidebar(_:)`.

### Title band

The toolbar carries only `.toggleSidebar` and `.sidebarTrackingSeparator`,
which keeps the toggle over the sidebar pane. The band is still 40pt
(`frame.height - contentLayoutRect.height`, measured with the toggle
present), matching `kMacTitleBarOverlap`. `sendEvent` diverts title band
double-clicks to Flutter only over the Flutter pane; over the sidebar pane
AppKit's own title bar runs the system action.

### Collapsing

The content pane has a 480pt minimum and the sidebar
`canCollapseFromWindowResize`, so a live resize narrower than both minimums
collapses the sidebar. A programmatic `setFrame` does not: it stops at the
window's minimum width (720 with a 240pt sidebar). The toolbar toggle
restores it. The width is autosaved under `MydiaSidebar`; a first launch
starts at 240.

### Layout

- The current server's row (`action:source-header`) is drawn as an
  initials avatar with an up-down chevron, since it opens the server picker
  rather than a page.
- `nativeSidebarFor(grouped: true)` (macOS only) puts the middle rows under
  Library (`kLibrarySidebarIds` and `library-*`) and Filters (listings, saved
  filters, New filter), keeping their order within each.
- The `trailing` section leaves the scrolling list: its places (Downloads,
  Settings) pin to a footer below it, and its commands (Edit sidebar) move to
  the sidebar's context menu and the top of the View menu, beside Show/Hide
  Sidebar (Ctrl-Cmd-S). Settings is also Cmd-, in the app menu.

### Editing

Edit sidebar opens as a dialog on desktop rather than a sheet.

### The player

`setVisible(false)` also hides the toolbar, so the sidebar toggle is gone
over the player, and leaving fullscreen there keeps it hidden. The viewer's
collapsed choice is stored under `MydiaSidebarViewerCollapsed`, apart from
the split view's autosave, which also records a forced collapse.

The `ShellRoute` sets `notifyRootObserver: false`. Without it go_router
forwards every shell page to `PageCoverObserver`, which then reports Home
itself as covered and collapses the sidebar at launch.

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

### Device gate: in progress

Fill this in one line per item with the date, app version, iPhone model and
iOS version. Do not record a line that was not observed.

2026-10-15, iPhone 15 Pro Max, iOS 27.0.1, profile build from Xcode 27,
container root: Home takes touches and every tab switch renders, with no black
screen. Before the container root the same device reproduced both failures,
and a hierarchy dump showed the Flutter view with no superview.

From the spike (the lifecycle and plugin checks the simulator cannot show):

- [ ] Backgrounding and returning does not pause playback or raise the privacy
  blur spuriously (the Flutter view controller is never re-parented).
- [ ] Plugins that present UIKit (share sheet, pickers) work with
  `MydiaRootViewController` as root.
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

### iPad device gate: not started

Fill in one line per item with the date, app version, iPad model and iPadOS
version. Do not record a line that was not observed.

- [ ] Portrait: the sidebar overlays the content; a tap beside it dismisses
  it; the floating bar shows Home, Movies, Shows and Search.
- [ ] Landscape: the sidebar docks and the content sits beside it; hiding it
  moves the content back; no title row sits under the floating bar.
- [ ] Every row, the toggle and the floating bar take taps; scrolling and
  text entry work straight after a sidebar tap.
- [ ] Switching servers from the header row updates the rows; on All servers
  the Servers group switches to the tapped server.
- [ ] Edit sidebar: hide and reorder show up after Done.
- [ ] New filter opens the filter editor.
- [ ] Slide Over and a narrow Split View show the bottom bar with the phone's
  five entries; full screen brings the sidebar back on the same row.
- [ ] The player hides the sidebar; leaving it brings it back. A sheet or
  dialog from a content screen hides it too.
- [ ] A route with no row (e.g. a manage page) highlights nothing.
- [ ] Offline: every row but Downloads is dimmed and does nothing.
- [ ] A hardware keyboard and a trackpad reach the sidebar.
- [ ] No `unknown SF Symbol` or `unknown tab id` lines in the device log.

### macOS device gate: not started

Fill in one line per item with the date, app version, Mac model and macOS
version. Do not record a line that was not observed.

Recorded without a person at the Mac (2026-10-16, macOS 27.0.1, Xcode 27.0,
release build, NSLog self-test): the channel answers `mode` and `layout`;
`setChromeVisible(false)` collapses and `true` restores the shown state;
`chromeLeading` is 132 collapsed and 0 shown; the title band is 40.

- [ ] Rows and order match the Flutter rail on master for one server; the
  header row opens the picker beside the sidebar; switching servers updates
  the rows; All servers shows the Servers group and switching from it works.
- [ ] Dragging the window narrow collapses the sidebar; the toolbar toggle
  restores it; the shell never shows the phone bottom bar at any width.
- [ ] Sidebar shown: content title rows start at the pane's leading edge.
  Sidebar collapsed: content title rows clear the lights and the toggle.
- [ ] A title band double-click over the Flutter pane and over the sidebar
  each run the system action once.
- [ ] Keyboard: Tab into the sidebar, arrows move and navigate, type-select
  works.
- [ ] New filter opens; Edit sidebar opens as a dialog, a reorder shows after
  Done, a click outside closes it without popping the page.
- [ ] Dialogs, sheets and the picker leave the sidebar alone.
- [ ] The player collapses the sidebar; leaving restores it; a sidebar the
  viewer collapsed stays collapsed after the player.
- [ ] Fullscreen: toolbar hidden, sidebar usable, no stray chrome inset.
- [ ] Sparkle "Check for Updates" and the app menu still work.
- [ ] No `unknown SF Symbol` or `unknown tab id` lines in the log.

## Known limits

- Status-bar tap scroll-to-top after the root swap is unverified: Flutter
  forwards some behavior only when the root is a `FlutterViewController`, and
  the root is now `MydiaRootViewController`. Check on device.
- Cast artwork in the native accessory is fetched by `URLSession` and is
  subject to App Transport Security. Plain-http artwork fails to load and the
  accessory keeps the state symbol.
- iPad: arrow keys move focus inside Flutter or inside the sidebar, but do
  not cross from the content into UIKit's sidebar or back.
- iPad: there is no rail pinning. The sidebar's shown/hidden state is
  UIKit's, toggled by its own button.
- iPad: while a Flutter popup is open (the source picker, a sheet), the whole
  native sidebar fades out, leaving its strip empty in landscape.
- macOS: while the sidebar is collapsed the toggle sits in the Flutter pane's
  title band, so a double-click on it is diverted to Flutter like any other
  band double-click.

## Adding a Swift file to the Runner

The same four entries apply to `macos/Runner.xcodeproj/project.pbxproj`;
mirror `MainFlutterWindow.swift`'s entries for a macOS file.

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
