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
    // Saved filters are ordinary unanchored rows and belong in `middle`,
    // above the bottom anchors. Never special-case FilterDestination into a
    // group after `trailing`: that renders custom filters below Settings,
    // which contradicts the approved layout.
    final middle = resolved.where((d) => !d.isAnchored).toList();

    return [...leading, ...middle, ...trailing];
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

  /// The middle rows edit mode arranges, hidden ones included.
  ///
  /// Anchors are excluded entirely. They cannot be reordered or hidden, and
  /// `SidebarContent` renders them outside the reorderable region, so putting
  /// them in this list would misalign every index the reorder callback reports.
  List<SidebarEditRow> reconcileForEditing({required bool downloadSupported}) {
    final layout = reconcileLayout(downloadSupported: downloadSupported);

    final rows = <SidebarEditRow>[];
    for (final id in layout.order) {
      final NavDestination? destination =
          _builtinsById[id] ?? layout.filters[id];
      if (destination == null) continue;
      if (destination.isAnchored) continue;

      rows.add(
        SidebarEditRow(
          destination: destination,
          hidden: layout.hidden.contains(id),
        ),
      );
    }
    return rows;
  }

  /// The full stored order after edit mode moves one middle row.
  ///
  /// [oldIndex] and [newIndex] index [reconcileForEditing]'s output, and the
  /// middle list here is built from that same call so the two cannot drift.
  ///
  /// `ReorderableListView` reports [newIndex] as a position in the list
  /// *before* the dragged row is removed, so it is decremented when it sits
  /// past [oldIndex]. Dropping that adjustment is an off-by-one that appears
  /// only on downward drags.
  ///
  /// Anchors are reassembled around the result rather than carried through the
  /// move. Their relative order does not matter here because [reconcile] sorts
  /// anchors by `defaultIndex` at render time regardless of stored order.
  List<String> orderAfterReorder({
    required int oldIndex,
    required int newIndex,
    required bool downloadSupported,
  }) {
    final layout = reconcileLayout(downloadSupported: downloadSupported);

    final middle = reconcileForEditing(downloadSupported: downloadSupported)
        .map((row) => row.destination.id)
        .toList();
    final middleIds = middle.toSet();

    final leading = <String>[];
    final trailing = <String>[];
    for (final id in layout.order) {
      if (middleIds.contains(id)) continue;
      final builtin = _builtinsById[id];
      if (builtin != null && _anchorsToTop(builtin)) {
        leading.add(id);
      } else {
        trailing.add(id);
      }
    }

    var target = newIndex;
    if (target > oldIndex) target -= 1;

    final moved = middle.removeAt(oldIndex);
    middle.insert(target, moved);

    return [...leading, ...middle, ...trailing];
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

/// One middle row as edit mode sees it.
///
/// Edit mode renders hidden rows in place so the user can see where a restored
/// row will land, which is why it cannot reuse [SidebarLayout.reconcile]'s
/// output: that drops hidden rows entirely.
class SidebarEditRow {
  const SidebarEditRow({required this.destination, required this.hidden});

  final NavDestination destination;
  final bool hidden;

  @override
  bool operator ==(Object other) =>
      other is SidebarEditRow &&
      other.destination.id == destination.id &&
      other.hidden == hidden;

  @override
  int get hashCode => Object.hash(destination.id, hidden);

  @override
  String toString() => 'SidebarEditRow(${destination.id}, hidden: $hidden)';
}
