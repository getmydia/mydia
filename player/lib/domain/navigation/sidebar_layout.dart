import 'nav_destination.dart';

/// The user's arrangement of the sidebar.
///
/// Stored as opaque ids rather than destinations so that a release which adds
/// or removes a destination reconciles cleanly instead of failing to parse.
class SidebarLayout {
  const SidebarLayout({
    required this.order,
    required this.hidden,
    required this.filters,
  });

  final List<String> order;
  final Set<String> hidden;
  final Map<String, FilterDestination> filters;

  /// The arrangement a user sees before they touch anything, and the one a
  /// user with unreadable stored state falls back to.
  static final SidebarLayout defaults = SidebarLayout(
    order: (List.of(builtinDestinations)
          ..sort((a, b) => a.defaultIndex.compareTo(b.defaultIndex)))
        .map((d) => d.id)
        .toList(),
    hidden: const {},
    filters: const {},
  );

  static final Map<String, BuiltinDestination> _builtinsById = {
    for (final destination in builtinDestinations) destination.id: destination,
  };

  /// Resolves stored ids into the destinations to render, in render order.
  ///
  /// Applies all five reconciliation rules, drops hidden rows, and pins
  /// anchors to the edges.
  List<NavDestination> reconcile({required bool downloadSupported}) {
    final layout = reconcileLayout(downloadSupported: downloadSupported);

    final resolved = <NavDestination>[];
    for (final id in layout.order) {
      if (layout.hidden.contains(id)) continue;

      final builtin = _builtinsById[id];
      if (builtin != null) {
        resolved.add(builtin);
        continue;
      }
      final filter = layout.filters[id];
      if (filter != null) resolved.add(filter);
    }

    // Anchors are ordered by defaultIndex, never by stored order. A user who
    // dragged Settings above Downloads before those rows became anchored must
    // still get Downloads above Settings, or the edges render arbitrarily.
    int anchorRank(NavDestination d) => _builtinsById[d.id]?.defaultIndex ?? 0;

    final leading = resolved
        .where((d) => d.isAnchored && _anchorsToTop(d))
        .toList()
      ..sort((a, b) => anchorRank(a).compareTo(anchorRank(b)));
    final trailing = resolved
        .where((d) => d.isAnchored && !_anchorsToTop(d))
        .toList()
      ..sort((a, b) => anchorRank(a).compareTo(anchorRank(b)));
    final middle = resolved.where((d) => !d.isAnchored).toList();
    final middleBuiltins =
        middle.where((d) => d is! FilterDestination).toList();
    final trailingFilters = middle.whereType<FilterDestination>().toList();

    return [...leading, ...middleBuiltins, ...trailing, ...trailingFilters];
  }

  /// Search anchors to the top; every other anchor sits at the bottom.
  static bool _anchorsToTop(NavDestination destination) =>
      destination.id == 'search';

  /// The reconciled *state*, before hidden rows are dropped.
  ///
  /// Split from [reconcile] so the store can persist a cleaned layout and the
  /// settings UI can list hidden rows in order to offer un-hiding them.
  SidebarLayout reconcileLayout({required bool downloadSupported}) {
    final availableBuiltins = {
      for (final destination in builtinDestinations)
        if (downloadSupported || !destination.requiresDownloadSupport)
          destination.id: destination,
    };

    // Rule 1: drop ids matching neither a builtin nor a stored filter.
    final kept = order
        .where((id) =>
            availableBuiltins.containsKey(id) || filters.containsKey(id))
        .toList();

    // Rule 2: insert absent builtins at their defaultIndex rather than
    // appending, so a destination added in a later release lands where it was
    // designed to rather than below the user's saved filters.
    final present = kept.toSet();
    final missing = availableBuiltins.values
        .where((destination) => !present.contains(destination.id))
        .toList()
      ..sort((a, b) => a.defaultIndex.compareTo(b.defaultIndex));

    for (final destination in missing) {
      final insertAt = _insertionPoint(kept, destination, availableBuiltins);
      kept.insert(insertAt, destination.id);
    }

    // Rule 3: append stored filters missing from order.
    for (final id in filters.keys) {
      if (!kept.contains(id)) kept.add(id);
    }

    // Rule 4: intersect hidden with the reconciled id set, and never let an
    // anchored destination be hidden.
    final reconciledHidden = hidden
        .where((id) => kept.contains(id))
        .where((id) => !(availableBuiltins[id]?.isAnchored ?? false))
        .toSet();

    return SidebarLayout(
      order: kept,
      hidden: reconciledHidden,
      filters: filters,
    );
  }

  /// Where [destination] belongs in [ids]: after the last builtin with a lower
  /// `defaultIndex`. Filters and unknown ids do not move the insertion point.
  static int _insertionPoint(
    List<String> ids,
    BuiltinDestination destination,
    Map<String, BuiltinDestination> availableBuiltins,
  ) {
    var insertAt = 0;
    for (var i = 0; i < ids.length; i++) {
      final other = availableBuiltins[ids[i]];
      if (other != null && other.defaultIndex < destination.defaultIndex) {
        insertAt = i + 1;
      }
    }
    return insertAt;
  }

  SidebarLayout copyWith({
    List<String>? order,
    Set<String>? hidden,
    Map<String, FilterDestination>? filters,
  }) {
    return SidebarLayout(
      order: order ?? this.order,
      hidden: hidden ?? this.hidden,
      filters: filters ?? this.filters,
    );
  }

  SidebarLayout reordered(List<String> newOrder) => copyWith(order: newOrder);

  SidebarLayout withHidden(String id) => copyWith(hidden: {...hidden, id});

  SidebarLayout withUnhidden(String id) =>
      copyWith(hidden: hidden.where((existing) => existing != id).toSet());

  SidebarLayout withFilter(FilterDestination destination) {
    return copyWith(
      order:
          order.contains(destination.id) ? order : [...order, destination.id],
      filters: {...filters, destination.id: destination},
    );
  }

  SidebarLayout withoutFilter(String id) {
    return copyWith(
      order: order.where((existing) => existing != id).toList(),
      filters: {...filters}..remove(id),
      hidden: hidden.where((existing) => existing != id).toSet(),
    );
  }

  Map<String, dynamic> toJson() => {
        'order': order,
        'hidden': hidden.toList(),
        'filters': {
          for (final entry in filters.entries) entry.key: entry.value.toJson(),
        },
      };

  /// Rule 5: anything unreadable yields [defaults] rather than throwing.
  factory SidebarLayout.fromJson(Map<String, dynamic> json) {
    try {
      final rawFilters = json['filters'] as Map? ?? const {};

      return SidebarLayout(
        order: (json['order'] as List).cast<String>(),
        hidden: ((json['hidden'] as List?) ?? const []).cast<String>().toSet(),
        filters: {
          for (final entry in rawFilters.entries)
            entry.key as String: FilterDestination.fromJson(
              Map<String, dynamic>.from(entry.value as Map),
            ),
        },
      );
    } catch (_) {
      return defaults;
    }
  }

  @override
  bool operator ==(Object other) {
    if (other is! SidebarLayout) return false;
    if (other.order.length != order.length) return false;
    for (var i = 0; i < order.length; i++) {
      if (other.order[i] != order[i]) return false;
    }
    if (other.hidden.length != hidden.length) return false;
    if (!other.hidden.containsAll(hidden)) return false;
    if (other.filters.length != filters.length) return false;
    for (final entry in filters.entries) {
      if (other.filters[entry.key] != entry.value) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
        Object.hashAll(order),
        Object.hashAllUnordered(hidden),
        Object.hashAllUnordered(filters.keys),
      );

  @override
  String toString() =>
      'SidebarLayout(order: $order, hidden: $hidden, filters: ${filters.keys})';
}
