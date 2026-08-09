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
}

class HiveSidebarLayoutStore implements SidebarLayoutStore {
  const HiveSidebarLayoutStore(this._box);

  static const boxName = 'sidebar_layout';

  /// There is one sidebar, so one key.
  static const _key = 'layout';

  final Box<Map> _box;

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
}

/// Used when the Hive box will not open. The arrangement simply does not
/// persist this session.
class InMemorySidebarLayoutStore implements SidebarLayoutStore {
  SidebarLayout? _layout;

  @override
  SidebarLayout? get() => _layout;

  @override
  Future<void> save(SidebarLayout layout) async => _layout = layout;
}
