import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:hive_ce_flutter/hive_flutter.dart';

import '../../domain/navigation/sidebar_layout.dart';

/// Persists the user's sidebar arrangement.
///
/// An interface rather than a concrete class so a box that will not open costs
/// the user persistence for the session and never the ability to navigate.
abstract class SidebarLayoutStore {
  SidebarLayout? get();
  Future<void> save(SidebarLayout layout);

  /// Whether the floating rail stays expanded. Per device, never synced.
  bool get railPinned;
  Future<void> saveRailPinned(bool pinned);
}

class HiveSidebarLayoutStore implements SidebarLayoutStore {
  const HiveSidebarLayoutStore(this._box);

  static const boxName = 'sidebar_layout';

  /// There is one sidebar, so one key.
  static const _key = 'layout';

  /// The rail pin shares the box under its own key. It stays a map because the
  /// box is typed `Map`, and it never touches the layout record.
  static const _railKey = 'rail';

  final Box<Map<dynamic, dynamic>> _box;

  @override
  SidebarLayout? get() {
    final raw = _box.get(_key);
    if (raw == null) return null;

    try {
      return SidebarLayout.fromJson(Map<String, dynamic>.from(raw));
    } catch (e) {
      // A malformed record must never cost the user their navigation. Drop it
      // and fall back to the defaults.
      debugPrint('[SidebarLayout] Discarding unreadable record: $e');
      unawaited(_box.delete(_key));
      return null;
    }
  }

  @override
  Future<void> save(SidebarLayout layout) => _box.put(_key, layout.toJson());

  @override
  bool get railPinned => _box.get(_railKey)?['pinned'] == true;

  @override
  Future<void> saveRailPinned(bool pinned) =>
      _box.put(_railKey, {'pinned': pinned});
}

/// Used when the Hive box will not open. The arrangement simply does not
/// persist this session.
class InMemorySidebarLayoutStore implements SidebarLayoutStore {
  SidebarLayout? _layout;
  bool _railPinned = false;

  @override
  SidebarLayout? get() => _layout;

  @override
  Future<void> save(SidebarLayout layout) async => _layout = layout;

  @override
  bool get railPinned => _railPinned;

  @override
  Future<void> saveRailPinned(bool pinned) async => _railPinned = pinned;
}
