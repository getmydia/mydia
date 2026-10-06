import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart' show immutable;

/// A restart-stable identity for one GraphQL operation plus its variables.
///
/// `Request` (gql_exec) has value equality, but its `hashCode` is not stable
/// across app restarts, so it cannot key a persisted store such as the fetch
/// log. [QueryKey] is also what the invalidation rules refer to.
///
/// Deliberately *not* `const`-constructible: `canonical` below is a `late
/// final` field, memoized once per instance, and Dart forbids `late final`
/// fields (and non-final ones) in any class that declares a const generative
/// constructor, full stop, regardless of whether a given call site actually
/// uses `const`. The catalog below relies on that memoization: `QueryKeys.home`
/// and friends are `static final` singletons, each looked up by every
/// `FreshnessHeader` build for as long as the app runs, so computing
/// `canonical` once per singleton (instead of once per lookup) is the whole
/// point.
@immutable
class QueryKey {
  QueryKey(this.operationName, [this.variables = const {}]);

  final String operationName;
  final Map<String, dynamic> variables;

  /// Stable string form: the persisted fetch-log key.
  ///
  /// `late final` rather than a getter: this backs `==`/`hashCode` below, so
  /// it runs on every registry lookup and every header build. Computed once
  /// per instance and cached from then on.
  late final String canonical =
      '$operationName(${jsonEncode(_sortKeys(variables))})';

  static Object? _sortKeys(Object? value) {
    if (value is Map) {
      final sorted = SplayTreeMap<String, Object?>();
      value.forEach((key, dynamic entry) => sorted['$key'] = _sortKeys(entry));
      return sorted;
    }
    if (value is List) {
      return value.map<Object?>(_sortKeys).toList();
    }
    return value;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is QueryKey && other.canonical == canonical);

  @override
  int get hashCode => canonical.hashCode;

  @override
  String toString() => canonical;
}
