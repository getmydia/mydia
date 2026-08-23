import 'package:flutter/foundation.dart' show debugPrint;
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../domain/navigation/nav_destination.dart';
import '../../domain/navigation/sidebar_layout.dart';
import '../downloads/download_service.dart' show isDownloadSupported;
import 'sidebar_layout_store.dart';

part 'sidebar_layout_providers.g.dart';

/// Opens the box, falling back to an in-memory store rather than failing the
/// whole sidebar if Hive will not open.
@Riverpod(keepAlive: true)
Future<SidebarLayoutStore> sidebarLayoutStoreAsync(Ref ref) async {
  try {
    final box = await Hive.openBox<Map>(HiveSidebarLayoutStore.boxName);
    return HiveSidebarLayoutStore(box);
  } catch (e) {
    debugPrint('[SidebarLayout] Box unavailable, not persisting: $e');
    return InMemorySidebarLayoutStore();
  }
}

/// Overridden in tests and by [sidebarLayoutStoreAsync] at runtime.
@Riverpod(keepAlive: true)
SidebarLayoutStore sidebarLayoutStore(Ref ref) {
  throw UnimplementedError(
    'sidebarLayoutStoreProvider must be overridden. At app start this is '
    'done from sidebarLayoutStoreAsyncProvider; in tests, override it with '
    'an InMemorySidebarLayoutStore.',
  );
}

/// The stored arrangement, reconciled against the current builtin registry.
@riverpod
Future<SidebarLayout> sidebarLayout(Ref ref) async {
  final store = ref.watch(sidebarLayoutStoreProvider);
  final stored = store.get() ?? SidebarLayout.defaults;
  return stored.reconcileLayout(downloadSupported: isDownloadSupported);
}

/// The rows to render, in render order, with hidden rows already removed.
@riverpod
Future<List<NavDestination>> sidebarDestinations(Ref ref) async {
  final layout = await ref.watch(sidebarLayoutProvider.future);
  return layout.reconcile(downloadSupported: isDownloadSupported);
}

/// Whether the sidebar is in edit mode.
///
/// Presentation state, never persisted: a relaunch always starts in normal
/// mode. It lives in a provider rather than widget state because the desktop
/// sidebar and the mobile drawer each build their own `SidebarContent`, and
/// `Scaffold.drawer` keeps its child mounted while closed, so local state would
/// leave the drawer in edit mode the next time it opened.
@Riverpod(keepAlive: true)
class SidebarEditMode extends _$SidebarEditMode {
  @override
  bool build() => false;

  void toggle() => state = !state;

  void exit() => state = false;
}

/// The middle rows edit mode arranges, hidden ones included.
///
/// Distinct from [sidebarDestinations], which drops hidden rows and keeps
/// anchors. Edit mode needs the opposite of both.
@riverpod
Future<List<SidebarEditRow>> sidebarEditRows(Ref ref) async {
  final layout = await ref.watch(sidebarLayoutProvider.future);
  return layout.reconcileForEditing(downloadSupported: isDownloadSupported);
}

@riverpod
SidebarLayoutController sidebarLayoutController(Ref ref) =>
    SidebarLayoutController(ref);

/// Mutations. Every one writes through the store then invalidates the layout
/// provider, so the sidebar and drawer repaint together.
class SidebarLayoutController {
  const SidebarLayoutController(this._ref);

  final Ref _ref;

  SidebarLayoutStore get _store => _ref.read(sidebarLayoutStoreProvider);

  Future<void> _mutate(SidebarLayout Function(SidebarLayout) change) async {
    final current = _store.get() ?? SidebarLayout.defaults;
    await _store.save(change(current));
    _ref.invalidate(sidebarLayoutProvider);
  }

  Future<void> reorder(List<String> order) =>
      _mutate((layout) => layout.reordered(order));

  Future<void> hide(String id) => _mutate((layout) => layout.withHidden(id));

  Future<void> unhide(String id) =>
      _mutate((layout) => layout.withUnhidden(id));

  Future<void> addFilter(FilterDestination destination) =>
      _mutate((layout) => layout.withFilter(destination));

  Future<void> updateFilter(FilterDestination destination) =>
      _mutate((layout) => layout.withFilter(destination));

  Future<void> deleteFilter(String id) =>
      _mutate((layout) => layout.withoutFilter(id));

  /// Restores default order and unhides everything, keeping saved filters.
  ///
  /// `SidebarLayout.defaults` carries `filters: const {}`, so assigning it
  /// wholesale would delete every saved filter rather than rearranging. Filters
  /// are user-created content and the reset affordance is about arrangement.
  /// Rule 3 in `reconcileLayout` appends the preserved filters back onto the
  /// default order, so they return at the bottom of the list.
  Future<void> resetToDefaults() => _mutate(
        (layout) => SidebarLayout(
          order: SidebarLayout.defaults.order,
          hidden: const {},
          filters: layout.filters,
        ),
      );
}
