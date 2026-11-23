/// Native desktop window management, backed by window_manager's and
/// screen_retriever's native API (nativeapi), through [NativeWindowHost].
///
/// `dart.library.io` is also true on iOS and Android, so every entry point
/// here gates on [PlatformFeatures.isDesktop] as well.
///
/// Nothing here is allowed to throw. [initDesktopWindow] runs inside
/// `_startApp`, whose stated invariant is that nothing after
/// `WidgetsFlutterBinding.ensureInitialized()` escapes uncaught, and
/// [startWindowDrag] runs from a pointer handler where an exception would
/// surface as a red screen mid-playback.
///
/// nativeapi's calls are synchronous FFI calls, and every one can throw: when
/// the native library is not loaded, or before a window can be found. That is
/// what the `try` blocks are for.
library;

import 'package:flutter/foundation.dart';
// Re-exports hive_ce, so this one import covers both Hive and Box.
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import '../player/platform_features.dart';
import '../storage/app_hive.dart';
import 'native_window_host.dart';
import 'player_window_session.dart';
import 'player_window_sizer.dart';
import 'player_window_sizer_native.dart';
import 'window_controller_native.dart';
import 'window_fullscreen_controller.dart';
import 'window_geometry_controller.dart';
import 'window_geometry_math.dart';
import 'window_geometry_store.dart';
import 'window_maximized_controller.dart';

/// Retained so [createPlayerWindowSizer] can pause and resume it. Null until
/// [initDesktopWindow] succeeds, and on every non-desktop platform.
WindowGeometryController? _geometry;

/// Shared by every player screen's sizer; see [PlayerWindowSession]. Null
/// until [initDesktopWindow] succeeds, and on every non-desktop platform.
PlayerWindowSession? _playerSession;

/// Prepares the OS window: minimum size, restored geometry, drag support, and
/// change tracking.
Future<void> initDesktopWindow() async {
  if (!PlatformFeatures.isDesktop) return;

  final host = NativeWindowHost.instance;
  try {
    host.requireWindow();
  } catch (e) {
    debugPrint('[DesktopWindow] Failed to find the native window: $e');
    // Without a window there is nothing to restore or track. Dragging is
    // separately guarded, so there is nothing further to do here.
    return;
  }

  if (defaultTargetPlatform == TargetPlatform.windows) {
    try {
      host.requireWindow().titleBarStyle = TitleBarStyle.hidden;
    } catch (e) {
      debugPrint('[DesktopWindow] Failed to set title bar style: $e');
    }
  }

  final store = await _openStore();
  final controller = WindowGeometryController(
    window: const WindowManagerController(),
    store: store,
    readWorkAreas: _readWorkAreas,
  );

  await controller.restore();

  try {
    host.addListener(controller);
    _geometry = controller;
  } catch (e) {
    debugPrint('[DesktopWindow] Failed to track window geometry: $e');
  }

  final session = PlayerWindowSession(
    window: const WindowManagerController(),
    geometry: controller,
  );
  _playerSession = session;
  try {
    // Without the listener a fullscreen exit is only noticed by the
    // session's timeout, which still ends it, just later.
    host.addListener(session);
  } catch (e) {
    debugPrint('[DesktopWindow] Failed to watch fullscreen exit: $e');
  }

  // Separate try from the geometry listener above: a failure to track
  // fullscreen costs a `kMacTitleBarOverlap` inset in fullscreen, which must
  // not also cost geometry persistence, and vice versa.
  try {
    final fullscreen = WindowFullscreenController(
      window: const WindowManagerController(),
    );
    await fullscreen.seed();
    host.addListener(fullscreen);
  } catch (e) {
    debugPrint('[DesktopWindow] Failed to track fullscreen state: $e');
  }

  // Separate try from the fullscreen listener above, for the same reason it
  // is separate from the geometry one: a failure to track maximized state
  // costs a stale maximize glyph, which must not also cost fullscreen
  // tracking or geometry persistence.
  try {
    final maximized = WindowMaximizedController(
      window: const WindowManagerController(),
    );
    await maximized.seed();
    host.addListener(maximized);
  } catch (e) {
    debugPrint('[DesktopWindow] Failed to track maximized state: $e');
  }
}

/// Reads the current displays as work areas.
///
/// `workArea` is the screen minus menu bars, docks and taskbars. A display
/// reporting an empty one is skipped rather than guessed at — a wrong rect
/// here puts the window somewhere unreachable.
Future<List<WorkArea>> _readWorkAreas() async {
  try {
    final displays = DisplayManager.instance.getAll();
    try {
      final areas = <WorkArea>[];
      for (final display in displays) {
        final bounds = display.workArea.toRect();
        if (bounds.width <= 0 || bounds.height <= 0) continue;
        areas.add(WorkArea(bounds: bounds, isPrimary: display.isPrimary));
      }
      return areas;
    } finally {
      for (final display in displays) {
        display.dispose();
      }
    }
  } catch (e) {
    debugPrint('[DesktopWindow] Failed to read displays: $e');
    return const [];
  }
}

Future<WindowGeometryStore> _openStore() async {
  try {
    await initAppHive();
    return HiveWindowGeometryStore(
      await Hive.openBox<Map<dynamic, dynamic>>(
        HiveWindowGeometryStore.boxName,
      ),
    );
  } catch (e) {
    // Most likely a second instance holding the lock, which `_startApp`
    // handles on its own terms. Geometry just does not persist this session.
    debugPrint('[DesktopWindow] Failed to open geometry box: $e');
    return InMemoryWindowGeometryStore();
  }
}

void startWindowDrag() {
  if (!PlatformFeatures.isDesktop) return;
  try {
    NativeWindowHost.instance.requireWindow().startDragging();
  } catch (e) {
    debugPrint('[DesktopWindow] Failed to start window drag: $e');
  }
}

/// Pins or un-pins the OS window above other windows.
///
/// No-op off desktop. Never throws: called from a control-panel button tap
/// and from `PlayerScreen.dispose()`, neither of which can surface an
/// exception usefully — same contract as [startWindowDrag].
void setWindowAlwaysOnTop(bool value) {
  if (!PlatformFeatures.isDesktop) return;
  try {
    NativeWindowHost.instance.requireWindow().isAlwaysOnTop = value;
  } catch (e) {
    debugPrint('[DesktopWindow] Failed to set always-on-top: $e');
  }
}

/// Brings the window forward, e.g. for an MPRIS Raise. No-op off desktop.
/// Never throws.
Future<void> raiseDesktopWindow() async {
  if (!PlatformFeatures.isDesktop) return;
  try {
    NativeWindowHost.instance.requireWindow()
      ..show()
      ..focus();
  } catch (e) {
    debugPrint('[DesktopWindow] Failed to raise window: $e');
  }
}

/// A sizer for the player screen, or a no-op when there is no window to size.
PlayerWindowSizer createPlayerWindowSizer() {
  final session = _playerSession;
  if (!PlatformFeatures.isDesktop || _geometry == null || session == null) {
    return const NoopPlayerWindowSizer();
  }

  late final NativePlayerWindowSizer sizer;
  sizer = NativePlayerWindowSizer(
    window: const WindowManagerController(),
    session: session,
    readWorkAreas: _readWorkAreas,
    onDetached: () {
      try {
        NativeWindowHost.instance.removeListener(sizer);
      } catch (e) {
        debugPrint('[DesktopWindow] Failed to unregister sizer: $e');
      }
    },
  );

  try {
    NativeWindowHost.instance.addListener(sizer);
  } catch (e) {
    // Without the listener the aspect snap still works; the lock just is not
    // dropped on maximize or fullscreen.
    debugPrint('[DesktopWindow] Failed to watch for manual resize: $e');
  }
  return sizer;
}
