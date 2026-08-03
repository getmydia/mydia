import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hive_ce/hive.dart';

import 'window_geometry.dart';

abstract class WindowGeometryStore {
  /// Synchronous so startup can read it without another await on a path that
  /// is already several deep. Hive keeps an open box in memory.
  WindowGeometry? get();

  Future<void> save(WindowGeometry geometry);
}

/// Hive-backed store over a plain `Box<Map>` with no type adapter, matching
/// `HivePlaybackProgressStore` and `HiveCastSessionStore`.
class HiveWindowGeometryStore implements WindowGeometryStore {
  static const boxName = 'window_geometry';

  /// There is exactly one window, so exactly one key.
  static const _key = 'main';

  final Box<Map> _box;

  const HiveWindowGeometryStore(this._box);

  @override
  WindowGeometry? get() {
    final raw = _box.get(_key);
    if (raw == null) return null;

    try {
      return WindowGeometry.fromMap(raw);
    } catch (e) {
      // A malformed record must never cost the user a launch. Drop it and fall
      // back to the centered default.
      debugPrint('[WindowGeometry] Discarding unreadable record: $e');
      unawaited(_box.delete(_key));
      return null;
    }
  }

  @override
  Future<void> save(WindowGeometry geometry) =>
      _box.put(_key, geometry.toMap());
}

/// Used when the Hive box will not open — notably the second-instance lock
/// contention `_startApp` already handles. Geometry simply does not persist
/// this session.
class InMemoryWindowGeometryStore implements WindowGeometryStore {
  WindowGeometry? _geometry;

  @override
  WindowGeometry? get() => _geometry;

  @override
  Future<void> save(WindowGeometry geometry) async => _geometry = geometry;
}
