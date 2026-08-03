import 'dart:async';

import 'package:flutter/foundation.dart';

import 'window_controller.dart';
import 'window_geometry_math.dart';
import 'window_geometry_store.dart';

/// Supplies the current displays. Injected so tests need no plugin.
typedef WorkAreaReader = Future<List<WorkArea>> Function();

/// Restores the window's geometry at startup and keeps the store in step with
/// it afterwards.
///
/// Every method swallows its failures: this runs inside `_startApp`, which
/// documents an invariant that nothing after
/// `WidgetsFlutterBinding.ensureInitialized()` escapes uncaught.
class WindowGeometryController {
  final WindowController _window;
  final WindowGeometryStore _store;
  final WorkAreaReader _readWorkAreas;
  final Duration _debounce;

  WindowGeometryController({
    required WindowController window,
    required WindowGeometryStore store,
    required WorkAreaReader readWorkAreas,
    Duration debounce = const Duration(milliseconds: 500),
  })  : _window = window,
        _store = store,
        _readWorkAreas = readWorkAreas,
        _debounce = debounce;

  Duration get debounce => _debounce;

  /// Applies the stored geometry, or a centered default on a first launch.
  Future<void> restore() async {
    try {
      await _window.setMinimumSize(kMinWindowSize);
    } catch (e) {
      debugPrint('[WindowGeometry] Failed to set minimum size: $e');
    }

    try {
      final areas = await _readWorkAreas();
      final stored = _store.get();

      final target = stored == null
          ? defaultWindowRect(areas)
          : recoverOffscreenWindow(stored.bounds, areas);

      // Null means we could not read any display. Leave the window wherever
      // the OS put it rather than guessing at coordinates.
      if (target == null) return;

      await _window.setBounds(target);
      if (stored?.maximized ?? false) await _window.maximize();
    } catch (e) {
      debugPrint('[WindowGeometry] Failed to restore window geometry: $e');
    }
  }
}
