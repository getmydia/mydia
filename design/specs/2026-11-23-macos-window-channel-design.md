# macOS window channel

## Problem

On macOS the player's fullscreen button cannot leave fullscreen while a video
plays. It enters fullscreen, then every later tap asks to enter again, which
AppKit ignores. The button's icon never changes either.

The cause is wider than the button. Since window_manager 0.7 (`2cd779251`),
`lib/core/window/` reaches the OS window through nativeapi, whose calls are
synchronous FFI into AppKit on whatever thread Dart runs on. The macOS runner
keeps Dart off the main thread on purpose (`FLTEnableMergedPlatformUIThread`
is false; see `player/docs/playback.md`, "macOS keeps Dart off the main
thread"), because mpv's video output does `DispatchQueue.main.sync`. Called
from that thread, nativeapi's `WindowManager.getCurrent()` never finds the
window: on a debug build it returned nothing for five seconds of retries while
the window was on screen. `initDesktopWindow()` then gives up, and on macOS:

- `windowFullscreenSignal` never changes, so `FullscreenController.toggle()`
  always chooses enter, and the chrome's fullscreen icon is always "enter".
- Window geometry is neither restored at launch nor saved.
- The player no longer sizes the window to the video or restores the browse
  window afterwards (`PlayerWindowSession`, `NativePlayerWindowSizer`).
- Drag, always-on-top and raise silently do nothing.

Platform channel handlers run on the main thread, which is what AppKit needs
and what the mpv constraint leaves free.

## Goal

Every window operation and window event the player uses works on macOS while
Dart stays off the main thread. Windows and Linux are unchanged.

Success: during playback, the fullscreen button and Cmd+Ctrl+F enter and exit
fullscreen, and the icon follows the window, including transitions made with
the green button or the View menu. Window size and position survive a relaunch,
and the player resizes the window to the video and restores it on exit.

## Design

### Swift: `macos/Runner/WindowPlugin.swift`

A method channel, `dev.mydia.player/window`, created by `MainFlutterWindow`
next to `NativeTabBarPlugin` and `MpvSurfacePlugin`, holding a weak reference
to the window.

Calls from Dart (all answered on the main thread):

| method | arguments | result |
| --- | --- | --- |
| `getBounds` | | `{x, y, width, height}` |
| `setBounds` | `{x, y, width, height}` | |
| `isMaximized` | | bool: `isZoomed`, not miniaturized, not fullscreen |
| `isFullScreen` | | bool: `styleMask.contains(.fullScreen)` |
| `maximize` / `unmaximize` | | `zoom(nil)` when the state differs |
| `minimize` | | `miniaturize(nil)` |
| `close` | | `performClose(nil)` |
| `enterFullScreen` / `exitFullScreen` | | `toggleFullScreen(nil)` when the state differs |
| `setMinimumSize` | `{width, height}` | `minSize` |
| `setAspectRatio` | `{ratio}` | `contentAspectRatio`; 0 clears it (`resizeIncrements = 1x1`) |
| `startDragging` | | `performDrag(with: NSApp.currentEvent)` when there is one |
| `setAlwaysOnTop` | `{value}` | `level` `.floating` or `.normal` |
| `raise` | | `makeKeyAndOrderFront(nil)`, `NSApp.activate` |
| `getWorkAreas` | | `[{x, y, width, height, isPrimary}]` from `NSScreen.visibleFrame` |

Rects cross the channel with a top-left origin measured from the primary
screen (`NSScreen.screens[0]`), the convention nativeapi used, so geometry
already saved by 0.7 builds stays valid. The conversion lives in one small
pure function so a RunnerTests case can check it.

With no window, a call answers `FlutterError(code: "no_window")`.

Events to Dart, `invokeMethod` on the same channel, from `NSWindow`
notifications on this window only:

| event | source |
| --- | --- |
| `resized` | `didResize`; also derives `maximized` / `unmaximized` from `isZoomed`, as nativeapi does, since AppKit has no zoom notification |
| `moved` | `didMove` |
| `enteredFullScreen` / `exitedFullScreen` | `didEnterFullScreen` / `didExitFullScreen` |
| `minimized` / `restored` | `didMiniaturize` / `didDeminiaturize` |
| `closeRequested` | `willClose` |

### Dart

- `MacWindowChannel` (new, `lib/core/window/mac_window_channel.dart`): the
  channel, its method calls, and decoding of incoming events into the same
  translation `NativeWindowHost.handleEvent` performs today. It takes a
  `MethodChannel` so tests drive it with a mock handler.
- `WindowController`: `window_controller_native.dart` keeps
  `WindowManagerController` for Windows and Linux and adds
  `MacWindowChannelController`. A single factory picks one by platform, and
  every `const WindowManagerController()` call site uses the factory instead.
- `NativeWindowHost` gets the macOS source: on macOS it has no nativeapi
  `Window`, wires listeners to `MacWindowChannel`'s events, and its window
  lookups go through the channel. The `WindowEventListener` fan-out, the
  maximize/restore bookkeeping and the dedup of fullscreen transitions stay in
  one place and are shared.
- `desktop_window_native.dart`: `initDesktopWindow` checks for a window through
  the chosen controller, so it no longer bails on macOS. `startWindowDrag`,
  `setWindowAlwaysOnTop`, `raiseDesktopWindow` and `_readWorkAreas` go through
  the controller or channel on macOS. Nothing on macOS calls nativeapi.
- Fullscreen: `NativeFullscreenBackend.toggle` already reads the live state
  through `WindowManagerController().isFullScreen()` (commit `f5102bc7c`); it
  switches to the factory, so on macOS that read goes through the channel.
  Enter and exit stay on media_kit's `Utils.Enter/ExitNativeFullscreen`
  channel, which already works.

### Errors

Every call keeps the module's contract: nothing throws to callers that do not
already handle failure. Dart wraps `PlatformException` and
`MissingPluginException` the way it wraps nativeapi throws today, logging with
the existing `[DesktopWindow]` / `[NativeWindowHost]` prefixes.

## Testing

- Dart, mocked channel:
  - each `MacWindowChannelController` method sends the right call and decodes
    the reply, and a `no_window` error surfaces as a failed future;
  - incoming events reach `WindowEventListener`s as the nativeapi path does,
    including unmaximize versus restore from minimized, and duplicate
    fullscreen events collapse;
  - `initDesktopWindow`'s window check succeeds through the channel.
- The step-1 tests stay: `toggle` exits when the window reports fullscreen and
  the signal is stale.
- RunnerTests: the top-left conversion for a window on the primary screen and
  on a second screen placed above it.
- On a Mac, debug build: enter and exit fullscreen during playback by the
  button, Cmd+Ctrl+F and the green button, with the icon following each time;
  the window resizes to the video and is restored on exit; size and position
  survive a relaunch.

## Out of scope

- Windows and Linux: unchanged, still nativeapi.
- `FLTEnableMergedPlatformUIThread`: stays false.
- Upstream changes to nativeapi.
