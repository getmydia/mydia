import 'dart:collection';

import 'ambient_tint_colors.dart';

/// Recently resolved tints by artwork identity, so returning to a title (or
/// opening its detail screen from a focused card) never extracts twice.
class TintCache {
  TintCache({this.capacity = 200});

  final int capacity;
  final LinkedHashMap<String, AmbientTintColors> _entries = LinkedHashMap();

  int get length => _entries.length;

  AmbientTintColors? get(String key) {
    final value = _entries.remove(key);
    if (value != null) _entries[key] = value;
    return value;
  }

  void put(String key, AmbientTintColors value) {
    _entries.remove(key);
    _entries[key] = value;
    while (_entries.length > capacity) {
      _entries.remove(_entries.keys.first);
    }
  }
}
