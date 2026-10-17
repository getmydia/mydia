import 'dart:collection';

import 'ambient_tint_colors.dart';

/// Recently resolved tints by artwork identity, so returning to a title (or
/// opening its detail screen from a focused card) never extracts twice.
class TintCache {
  TintCache({this.capacity = 200});

  final int capacity;

  /// Null values are cached misses (no artwork colour), so they are not
  /// retried on every focus.
  final LinkedHashMap<String, AmbientTintColors?> _entries = LinkedHashMap();

  int get length => _entries.length;

  bool contains(String key) => _entries.containsKey(key);

  /// The cached tint for [key], refreshing its recency. Call [contains]
  /// first: null is both "no tint" and "not cached".
  AmbientTintColors? get(String key) {
    if (!_entries.containsKey(key)) return null;
    final value = _entries.remove(key);
    _entries[key] = value;
    return value;
  }

  void put(String key, AmbientTintColors? value) {
    _entries.remove(key);
    _entries[key] = value;
    while (_entries.length > capacity) {
      _entries.remove(_entries.keys.first);
    }
  }
}
