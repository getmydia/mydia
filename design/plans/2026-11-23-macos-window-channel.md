# macOS Window Channel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On macOS, route every window call and window event the player uses through a main-thread method channel instead of nativeapi, so fullscreen state, geometry and player window sizing work again while Dart stays off the main thread.

**Architecture:** A Swift `WindowPlugin` in the Runner serves `dev.mydia.player/window`. On the Dart side, `MacWindowChannel` wraps it, `MacWindowChannelController` implements the existing `WindowController` seam, and the channel's events are fed into `NativeWindowHost.handleEvent` as nativeapi `WindowEvent`s, so the listener fan-out and maximize/restore bookkeeping stay in one place. A factory, `nativeWindowController()`, picks the channel controller on macOS and `WindowManagerController` elsewhere.

**Tech Stack:** Flutter (Dart), Swift/AppKit, `FlutterMethodChannel`, window_manager 0.7 / nativeapi 0.6.2 (Windows and Linux only), XCTest.

**Spec:** `design/specs/2026-11-23-macos-window-channel-design.md`

## Global Constraints

- Channel name, exactly: `dev.mydia.player/window`.
- Method names (Dart → Swift), exactly: `getBounds`, `setBounds`, `isMaximized`, `isFullScreen`, `maximize`, `unmaximize`, `minimize`, `close`, `enterFullScreen`, `exitFullScreen`, `setMinimumSize`, `setAspectRatio`, `startDragging`, `setAlwaysOnTop`, `raise`, `getWorkAreas`.
- Event names (Swift → Dart), exactly: `resized`, `moved`, `maximized`, `unmaximized`, `enteredFullScreen`, `exitedFullScreen`, `minimized`, `restored`, `closeRequested`.
- Rect maps use keys `x`, `y`, `width`, `height` (doubles), top-left origin measured from `NSScreen.screens[0]`, the convention nativeapi used, so geometry saved by 0.7 builds stays valid. Work areas add `isPrimary` (bool).
- No window: Swift answers `FlutterError(code: "no_window", ...)`.
- macOS selection is `!kIsWeb && defaultTargetPlatform == TargetPlatform.macOS`, so tests can switch it with `debugDefaultTargetPlatformOverride`.
- Nothing in `lib/core/window/` throws to a caller that does not already handle failure; log with the file's existing `[DesktopWindow]` / `[NativeWindowHost]` prefix.
- Windows and Linux behaviour is unchanged. `FLTEnableMergedPlatformUIThread` stays `false`.
- Every Swift `WindowPlugin` handler runs on the main thread (Flutter delivers channel calls there); it never calls mpv.
- Player commands go through `./dev` (`./dev flutter test --concurrency=1 <paths>`, `./dev flutter analyze`); commits run inside the worktree with direnv loaded and are checked with `git show --stat`.
- No em dashes in comments, docs or commit messages.

## Review Focus

- **A `restored` (deminiaturize) of a window that was maximized:** the host must stay "maximized", so a later unzoom still reports `onWindowUnmaximize`. Pinned in Task 3.
- **Duplicate fullscreen notifications** (AppKit can post `didEnterFullScreen` once while the host already seeded `true`): listeners get one `onWindowEnterFullScreen`. Pinned in Task 3.
- **A second screen above the primary one** (negative top-left `y`): the rect conversion is a round trip. Pinned in Task 1.
- **A channel call before the window exists, or with no Runner handler** (`MissingPluginException` in plain `flutter test`): `initDesktopWindow`, `startWindowDrag`, `setWindowAlwaysOnTop` and `raiseDesktopWindow` still complete without throwing on macOS. Pinned in Task 4.
- **`setAspectRatio(0)`** after a lock: user resizes are free again (`resizeIncrements` 1x1 and `contentAspectRatio` cleared). Pinned by the Task 5 manual check, since AppKit sizing is not unit-testable here.

---

### Task 1: Swift `WindowPlugin`

**Files:**
- Create: `player/macos/Runner/WindowPlugin.swift`
- Modify: `player/macos/Runner/MainFlutterWindow.swift` (register next to `NativeTabBarPlugin` in `awakeFromNib`, keep a strong reference in a stored property like `nativeTabBar`)
- Modify: `player/macos/Runner.xcodeproj/project.pbxproj` (add `WindowPlugin.swift` to the Runner group and Sources phase, and `WindowPluginTests.swift` to RunnerTests, mirroring the `NativeTabBarPlugin.swift` / `MpvSurfacePluginTests.swift` entries; use fresh 24-hex IDs)
- Test: `player/macos/RunnerTests/WindowPluginTests.swift`

**Interfaces:**
- Produces (Swift): `final class WindowPlugin: NSObject` with `init(messenger: FlutterBinaryMessenger, window: NSWindow)`, and two pure statics:
  - `static func topLeftRect(_ frame: NSRect, primaryHeight: CGFloat) -> NSRect` (AppKit bottom-left frame → top-left rect)
  - `static func appKitFrame(_ rect: NSRect, primaryHeight: CGFloat) -> NSRect` (inverse)
- Produces (channel): every method and event in Global Constraints, with these argument shapes: `setBounds` rect map; `setMinimumSize` `{width, height}`; `setAspectRatio` `{ratio}`; `setAlwaysOnTop` `{value}`; `getWorkAreas` returns a list of rect maps plus `isPrimary`.

- [ ] **Step 1: Write the failing XCTest**

```swift
func testTopLeftOnPrimary() {
  let r = WindowPlugin.topLeftRect(NSRect(x: 100, y: 200, width: 800, height: 600), primaryHeight: 1000)
  XCTAssertEqual(r, NSRect(x: 100, y: 200, width: 800, height: 600)) // 1000 - 200 - 600 = 200
}
func testSecondScreenAboveRoundTrips() {
  let frame = NSRect(x: 0, y: 1100, width: 800, height: 600) // above a 1000pt primary
  let r = WindowPlugin.topLeftRect(frame, primaryHeight: 1000)
  XCTAssertEqual(r.origin.y, -700)
  XCTAssertEqual(WindowPlugin.appKitFrame(r, primaryHeight: 1000), frame)
}
```

- [ ] **Step 2: Implement `WindowPlugin`**

Conversion: `y' = primaryHeight - y - height` both ways. Method handling follows the spec table: `maximize`/`unmaximize` call `zoom(nil)` only when `isZoomed` differs; `enterFullScreen`/`exitFullScreen` call `toggleFullScreen(nil)` only when `styleMask.contains(.fullScreen)` differs; `isMaximized` is `isZoomed && !isMiniaturized && !fullScreen`; `setAspectRatio` with ratio > 0 sets `contentAspectRatio = NSSize(width: ratio, height: 1)`, with 0 sets `resizeIncrements = NSSize(width: 1, height: 1)` and `contentAspectRatio = .zero`; `startDragging` calls `performDrag(with:)` only when `NSApp.currentEvent` is non-nil; `setAlwaysOnTop` sets `level` `.floating`/`.normal`; `raise` calls `makeKeyAndOrderFront(nil)` then `NSApp.activate(ignoringOtherApps: true)`; `getWorkAreas` maps `NSScreen.screens` `visibleFrame` through `topLeftRect`, `isPrimary` for index 0. Unknown methods answer `FlutterMethodNotImplemented`; a nil (deallocated) window answers `no_window`.
Events: observe `NSWindow` notifications with `object: window` (`didResize`, `didMove`, `didEnterFullScreen`, `didExitFullScreen`, `didMiniaturize`, `didDeminiaturize`, `willClose`) and `invokeMethod(<event>, arguments: nil)`. On `didResize`, also compute `isMaximized` as above; when it differs from the last value sent, send `maximized` or `unmaximized` after `resized`. `restored` carries `{"maximized": Bool}`. Seed the last-maximized value at init.

- [ ] **Step 3: Register in `MainFlutterWindow.awakeFromNib`**, after `RegisterGeneratedPlugins`: `windowPlugin = WindowPlugin(messenger: flutterViewController.engine.binaryMessenger, window: self)`.

- [ ] **Step 4: Build and test on the Mac**

Run on alexandres-macbook-pro in `~/Code/mydia/player/macos`: `xcodebuild test -workspace Runner.xcworkspace -scheme Runner -destination 'platform=macOS' -only-testing:RunnerTests/WindowPluginTests`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add player/macos/Runner/WindowPlugin.swift player/macos/Runner/MainFlutterWindow.swift player/macos/Runner.xcodeproj/project.pbxproj player/macos/RunnerTests/WindowPluginTests.swift
git commit -m "feat(player): macOS window channel in the Runner"
```

---

### Task 2: Dart `MacWindowChannel` and controller factory

**Files:**
- Create: `player/lib/core/window/mac_window_channel.dart`
- Modify: `player/lib/core/window/window_chrome_channel.dart` (add `const String kMacWindowChannelName = 'dev.mydia.player/window';` with a comment naming `WindowPlugin.swift`)
- Modify: `player/lib/core/window/window_controller_native.dart` (add `MacWindowChannelController` and `nativeWindowController()`)
- Test: `player/test/core/window/mac_window_channel_test.dart`

**Interfaces:**
- Produces:
  - `bool get useMacWindowChannel` (top-level, in `mac_window_channel.dart`): `!kIsWeb && defaultTargetPlatform == TargetPlatform.macOS`.
  - `class MacWindowChannel` with `MacWindowChannel({MethodChannel channel = const MethodChannel(kMacWindowChannelName)})`, `static final MacWindowChannel instance`, and:
    - `Future<T?> invoke<T>(String method, [Object? args])`: `invokeMethod`, rethrowing (callers decide).
    - `void listen(void Function(String event, Map<Object?, Object?>? args) onEvent)`: installs the channel's handler.
    - `Future<List<WorkArea>> getWorkAreas()`: decodes, skipping areas with non-positive size; returns `[]` on any failure.
  - `Rect decodeRect(Object? raw)` / `Map<String, double> encodeRect(Rect r)` (top-level, same file).
  - `class MacWindowChannelController implements WindowController` with `const MacWindowChannelController([MacWindowChannel? channel])`, every method mapped to the same-named channel method (`isFullScreen`/`isMaximized` return `false` for a null reply; `setAspectRatio` sends `{'ratio': v}`).
  - `WindowController nativeWindowController()` in `window_controller_native.dart`: `MacWindowChannelController()` when `useMacWindowChannel`, else `const WindowManagerController()`.

- [ ] **Step 1: Write the failing tests** (mock handler via `TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler` on a test-only `MethodChannel('test/window')`)

```dart
test('getBounds decodes the top-left rect', () async {
  handler = (c) async => {'x': 10.0, 'y': 20.0, 'width': 800.0, 'height': 600.0};
  expect(await controller.getBounds(), const Rect.fromLTWH(10, 20, 800, 600));
  expect(calls.single.method, 'getBounds');
});
test('setBounds and setAspectRatio send the spec shapes', () async {
  await controller.setBounds(const Rect.fromLTWH(1, 2, 3, 4));
  await controller.setAspectRatio(0);
  expect(calls[0].arguments, {'x': 1.0, 'y': 2.0, 'width': 3.0, 'height': 4.0});
  expect(calls[1].arguments, {'ratio': 0.0});
});
test('a no_window error fails the future', () async {
  handler = (c) async => throw PlatformException(code: 'no_window');
  await expectLater(controller.isFullScreen(), throwsA(isA<PlatformException>()));
});
test('getWorkAreas decodes, skips empty areas, and is [] on failure', () async {
  handler = (c) async => [
    {'x': 0.0, 'y': 0.0, 'width': 1440.0, 'height': 875.0, 'isPrimary': true},
    {'x': 1440.0, 'y': 0.0, 'width': 0.0, 'height': 0.0, 'isPrimary': false},
  ];
  final areas = await channel.getWorkAreas();
  expect(areas.single.bounds, const Rect.fromLTWH(0, 0, 1440, 875));
  expect(areas.single.isPrimary, isTrue);
  handler = (c) async => throw PlatformException(code: 'no_window');
  expect(await channel.getWorkAreas(), isEmpty);
});
test('nativeWindowController picks the channel on macOS only', () {
  debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
  expect(nativeWindowController(), isA<MacWindowChannelController>());
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  expect(nativeWindowController(), isA<WindowManagerController>());
}); // reset the override in tearDown
```

- [ ] **Step 2: Run to verify they fail**

Run: `./dev flutter test --concurrency=1 test/core/window/mac_window_channel_test.dart`
Expected: FAIL, `mac_window_channel.dart` not found.

- [ ] **Step 3: Implement** the Interfaces above.

- [ ] **Step 4: Run to verify they pass** (same command). Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add player/lib/core/window/mac_window_channel.dart player/lib/core/window/window_chrome_channel.dart player/lib/core/window/window_controller_native.dart player/test/core/window/mac_window_channel_test.dart
git commit -m "feat(player): Dart side of the macOS window channel"
```

---

### Task 3: `NativeWindowHost` takes macOS events from the channel

**Files:**
- Modify: `player/lib/core/window/native_window_host.dart`
- Test: `player/test/core/window/native_window_host_test.dart`

**Interfaces:**
- Consumes: `MacWindowChannel.listen` (Task 2).
- Produces:
  - `void attachMacChannel(MacWindowChannel channel, {required bool fullScreen, required bool maximized})`: switches the host to channel mode, seeds `_fullScreen` and `_maximized`, and calls `channel.listen(handleMacEvent)`. In channel mode `window` returns `null` without calling `WindowManager.instance.getCurrent()`, and `addListener` only stores the listener.
  - `@visibleForTesting void handleMacEvent(String event, Map<Object?, Object?>? args)`: maps each event onto the existing `handleEvent` branches (`resized` → resize, `moved` → move, `maximized` → maximize, `unmaximized` → the restore-from-maximized path, `enteredFullScreen` / `exitedFullScreen` → `_setFullScreen`, `minimized` → minimized flag, `restored` → leave minimized and set `_maximized` from `args['maximized']` without emitting, `closeRequested` → `onWindowClose`). Unknown events are ignored.
  - Refactor so the `WindowRestoredEvent` branch and `handleMacEvent` share one private helper `_restored({required bool maximizedNow})`. The nativeapi path passes `_window?.isMaximized ?? false`, as today.

- [ ] **Step 1: Write the failing tests**, reusing `_Recorder`:

```dart
test('channel: resize, move and close pass straight through', ...);   // ['resize','move','close']
test('channel: maximized then unmaximized reports both', ...);         // ['maximize','unmaximize']
test('channel: restored from minimized into maximized keeps maximized', () {
  host..handleMacEvent('maximized', null)..handleMacEvent('minimized', null)
      ..handleMacEvent('restored', {'maximized': true})..handleMacEvent('unmaximized', null);
  expect(recorder.calls, ['maximize', 'unmaximize']);
});
test('channel: duplicate fullscreen events collapse', () {
  host..handleMacEvent('enteredFullScreen', null)..handleMacEvent('enteredFullScreen', null)
      ..handleMacEvent('exitedFullScreen', null);
  expect(recorder.calls, ['enterFullScreen', 'leaveFullScreen']);
});
test('channel: seeded fullscreen suppresses the first enter', ...);   // attachMacChannel(fullScreen: true) then enteredFullScreen → []
```

Existing nativeapi-path tests in this file must still pass unchanged.

- [ ] **Step 2: Run to verify they fail**

Run: `./dev flutter test --concurrency=1 test/core/window/native_window_host_test.dart`
Expected: FAIL, `handleMacEvent` not defined.

- [ ] **Step 3: Implement** the Interfaces above. Update the class comment to say macOS events come from `WindowPlugin` because nativeapi cannot see the window from Dart's off-main thread (link `player/docs/playback.md`, "macOS keeps Dart off the main thread").

- [ ] **Step 4: Run to verify they pass** (same command).

- [ ] **Step 5: Commit**

```bash
git add player/lib/core/window/native_window_host.dart player/test/core/window/native_window_host_test.dart
git commit -m "feat(player): NativeWindowHost takes macOS window events from the channel"
```

---

### Task 4: Wire macOS through the channel everywhere

**Files:**
- Modify: `player/lib/core/window/desktop_window_native.dart`
- Modify: `player/lib/core/player/fullscreen/fullscreen_backend_native.dart:46` (default `readWindowFullscreen` becomes `nativeWindowController().isFullScreen`)
- Modify: `player/lib/presentation/widgets/window_chrome/window_title_row.dart:165`, `player/lib/presentation/widgets/window_chrome/desktop_window_chrome.dart:93` (`?? nativeWindowController()`)
- Modify: `player/integration_test/mac_surface_test.dart:379,433` (use `nativeWindowController()`; `_window` becomes `final`)
- Test: `player/test/core/window/desktop_window_test.dart`

**Interfaces:**
- Consumes: `nativeWindowController()`, `MacWindowChannel.instance`, `useMacWindowChannel` (Task 2); `NativeWindowHost.attachMacChannel` (Task 3).
- Produces: no new API. Behaviour in `desktop_window_native.dart`:
  - Every `const WindowManagerController()` becomes `nativeWindowController()`.
  - `initDesktopWindow`, on macOS: read `isFullScreen()` and `isMaximized()` through `nativeWindowController()`. If either throws, log `[DesktopWindow] Failed to find the native window: $e` and return, as today. Otherwise call `host.attachMacChannel(MacWindowChannel.instance, fullScreen: ..., maximized: ...)` before any `host.addListener`. Off macOS, the existing `host.requireWindow()` check is unchanged.
  - `startWindowDrag`, `setWindowAlwaysOnTop`, `raiseDesktopWindow`, on macOS: `unawaited` channel calls (`startDragging`, `setAlwaysOnTop {value}`, `raise`) with `.catchError` logging. `_readWorkAreas` on macOS returns `MacWindowChannel.instance.getWorkAreas()`.
  - Update the library comment: macOS goes through `WindowPlugin`, everything else through nativeapi.

- [ ] **Step 1: Write the failing tests** in `desktop_window_test.dart`, with `debugDefaultTargetPlatformOverride = TargetPlatform.macOS` and a mock handler on `kMacWindowChannelName` that records calls:

```dart
test('on macOS, initDesktopWindow asks the channel, not nativeapi', () async {
  await initDesktopWindow();
  expect(calls.map((c) => c.method), containsAll(['isFullScreen', 'isMaximized']));
});
test('on macOS with no Runner handler, every entry point completes', () async {
  // no mock handler: MissingPluginException
  await expectLater(initDesktopWindow(), completes);
  expect(startWindowDrag, returnsNormally);
  expect(() => setWindowAlwaysOnTop(true), returnsNormally);
  await expectLater(raiseDesktopWindow(), completes);
});
test('on macOS, setWindowAlwaysOnTop sends {value}', () async {
  setWindowAlwaysOnTop(true);
  await pumpEventQueue();
  expect(calls.last.method, 'setAlwaysOnTop');
  expect(calls.last.arguments, {'value': true});
});
```

Note: `initDesktopWindow` keeps state in module-level fields (`_geometry`, `_playerSession`). If the tests interfere through it, add a `@visibleForTesting void debugResetDesktopWindow()` that clears both.

- [ ] **Step 2: Run to verify they fail**

Run: `./dev flutter test --concurrency=1 test/core/window/desktop_window_test.dart`
Expected: FAIL, no `isFullScreen` call recorded.

- [ ] **Step 3: Implement** the behaviour above.

- [ ] **Step 4: Run the window and fullscreen suites**

Run: `./dev flutter test --concurrency=1 test/core/window test/core/player/fullscreen test/presentation/screens/player/player_screen_fullscreen_test.dart test/presentation/widgets/window_chrome`
Expected: all pass. Then `cd player && ../dev flutter analyze`: no issues.

- [ ] **Step 5: Commit**

```bash
git add player/lib/core/window/desktop_window_native.dart player/lib/core/player/fullscreen/fullscreen_backend_native.dart player/lib/presentation/widgets/window_chrome/window_title_row.dart player/lib/presentation/widgets/window_chrome/desktop_window_chrome.dart player/integration_test/mac_surface_test.dart player/test/core/window/desktop_window_test.dart
git commit -m "fix(player): drive the macOS window through the main-thread channel"
```

---

### Task 5: Verify on the Mac, document, ship

**Files:**
- Modify: `player/docs/playback.md` ("macOS keeps Dart off the main thread": add a paragraph saying window_manager/nativeapi calls AppKit from the calling thread, so on macOS the window goes through `WindowPlugin` on `dev.mydia.player/window`; any new window call must be added there, not to nativeapi)

- [ ] **Step 1: Reset the Mac checkout**: on alexandres-macbook-pro, in `~/Code/mydia`, discard the temporary `[FSDIAG]` edits (`git checkout -- player/lib/core/window`), `git pull`, then `./dev player macos run` (Homebrew `flutter`/`pod` on `PATH`). Quit the release Mydia Player first; it holds the Hive locks.
- [ ] **Step 2: Run `xcodebuild test`** for `RunnerTests/WindowPluginTests` (Task 1 command). Expected: `** TEST SUCCEEDED **`.
- [ ] **Step 3: Ask the user to run the manual checks** and confirm each:
  1. Play a video. Enter fullscreen with the button: the icon switches to "exit".
  2. Exit with the button: the window leaves fullscreen.
  3. Repeat with Cmd+Ctrl+F and with the green button. The icon follows every time.
  4. The window resizes to the video on play and restores on exit.
  5. Resize and move the window, quit, relaunch: size and position are restored.
  6. Drag a resize after playback: no aspect lock remains.
  The log has no `[DesktopWindow] Failed to find the native window`.
- [ ] **Step 4: Update `player/docs/playback.md`** as above. Commit with `git commit -m "docs(player): macOS window calls go through WindowPlugin"`.
- [ ] **Step 5: Push and open the PR** (`git push origin HEAD:fix/player-macos-fullscreen-exit`, `gh pr create`, no draft, auto-merge off), then follow CI and CodeRabbit to merge per the babysitting rules.
