/// Native desktop window management, backed by `window_manager` and
/// `screen_retriever`.
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
/// A genuinely synchronous throw is possible one step before any plugin call,
/// evaluating the `windowManager` getter: it lazily constructs a
/// `WindowManager._()` singleton that calls `setMethodCallHandler` before a
/// Flutter binding may exist, which is an assertion failure rather than a
/// `MissingPluginException`. In the running app this never fires, but
/// `desktop_window_test.dart` calls these entry points from bare `test()`s
/// with no binding, so every access hits it. That is what the outer `try`
/// blocks are for.
library;

import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
// Re-exports hive_ce, so this one import covers Hive, Box and initFlutter.
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import '../player/platform_features.dart';
import 'player_window_sizer.dart';
import 'player_window_sizer_native.dart';
import 'window_controller_native.dart';
import 'window_geometry_controller.dart';
import 'window_geometry_math.dart';
import 'window_geometry_store.dart';

/// Retained so [createPlayerWindowSizer] can pause and resume it. Null until
/// [initDesktopWindow] succeeds, and on every non-desktop platform.
WindowGeometryController? _geometry;

/// Prepares the OS window: minimum size, restored geometry, drag support, and
/// change tracking.
Future<void> initDesktopWindow() async {
  if (!PlatformFeatures.isDesktop) return;

  try {
    await windowManager.ensureInitialized();
  } catch (e) {
    debugPrint('[DesktopWindow] Failed to initialize window manager: $e');
    // Without the plugin there is no window to restore or track. Dragging is
    // separately guarded, so there is nothing further to do here.
    return;
  }

  final store = await _openStore();
  final controller = WindowGeometryController(
    window: const WindowManagerController(),
    store: store,
    readWorkAreas: _readWorkAreas,
  );

  await controller.restore();

  try {
    windowManager.addListener(controller);
    _geometry = controller;
  } catch (e) {
    debugPrint('[DesktopWindow] Failed to track window geometry: $e');
  }
}

/// Reads the current displays as work areas.
///
/// `visiblePosition` and `visibleSize` are the screen minus menu bars, docks
/// and taskbars. A display reporting either as null is skipped rather than
/// guessed at — a wrong rect here puts the window somewhere unreachable.
Future<List<WorkArea>> _readWorkAreas() async {
  try {
    final displays = await screenRetriever.getAllDisplays();
    final primary = await screenRetriever.getPrimaryDisplay();

    final areas = <WorkArea>[];
    for (final display in displays) {
      final position = display.visiblePosition;
      final size = display.visibleSize;
      if (position == null || size == null) continue;
      if (size.width <= 0 || size.height <= 0) continue;

      areas.add(WorkArea(
        bounds: Rect.fromLTWH(
          position.dx,
          position.dy,
          size.width,
          size.height,
        ),
        isPrimary: display.id == primary.id,
      ));
    }
    return areas;
  } catch (e) {
    debugPrint('[DesktopWindow] Failed to read displays: $e');
    return const [];
  }
}

Future<WindowGeometryStore> _openStore() async {
  try {
    await Hive.initFlutter();
    return HiveWindowGeometryStore(
      await Hive.openBox<Map>(HiveWindowGeometryStore.boxName),
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
    unawaited(
      windowManager.startDragging().catchError(
            (Object e) =>
                debugPrint('[DesktopWindow] Failed to start window drag: $e'),
          ),
    );
  } catch (e) {
    debugPrint('[DesktopWindow] Failed to start window drag: $e');
  }
}

/// A sizer for the player screen, or a no-op when there is no window to size.
PlayerWindowSizer createPlayerWindowSizer() {
  final geometry = _geometry;
  if (!PlatformFeatures.isDesktop || geometry == null) {
    return const NoopPlayerWindowSizer();
  }

  late final NativePlayerWindowSizer sizer;
  sizer = NativePlayerWindowSizer(
    window: const WindowManagerController(),
    geometry: geometry,
    readWorkAreas: _readWorkAreas,
    onDetached: () {
      try {
        windowManager.removeListener(sizer);
      } catch (e) {
        debugPrint('[DesktopWindow] Failed to unregister sizer: $e');
      }
    },
  );

  try {
    windowManager.addListener(sizer);
  } catch (e) {
    // Without the listener the aspect snap still works; it just cannot notice
    // a manual resize. Better than no sizing at all.
    debugPrint('[DesktopWindow] Failed to watch for manual resize: $e');
  }
  return sizer;
}
