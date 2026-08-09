import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/downloads/download_service.dart' show isDownloadSupported;
import '../../../core/navigation/sidebar_layout_providers.dart';
import '../../../core/theme/colors.dart';
import '../../../domain/navigation/nav_destination.dart';
import '../../../domain/navigation/sidebar_layout.dart';
import '../mydia_logo.dart';
import 'nav_badges.dart';
import 'sidebar_row.dart';

/// Shared sidebar navigation content used by both the desktop sidebar and the
/// mobile drawer.
class SidebarContent extends ConsumerWidget {
  const SidebarContent({
    super.key,
    required this.location,
    required this.onNavigate,
    required this.isOffline,
    this.backToMydiaWidget,
  });

  final String location;
  final ValueChanged<String> onNavigate;
  final bool isOffline;
  final Widget? backToMydiaWidget;

  /// The destination that should render as selected.
  ///
  /// Home lists the four discovery routes in `extraRoutes`, and each is also
  /// its own destination, so at `/favorites` two destinations match. The
  /// longest matching route wins, which selects Favorites rather than Home.
  static NavDestination? selectedFor(
    List<NavDestination> destinations,
    String location,
  ) {
    NavDestination? best;
    var bestLength = -1;

    for (final destination in destinations) {
      if (!destination.matches(location)) continue;
      if (destination.route.length > bestLength) {
        best = destination;
        bestLength = destination.route.length;
      }
    }
    return best;
  }

  /// Builds the full stored order after a middle-section reorder.
  ///
  /// Visible middle rows are reordered among themselves; hidden middle ids
  /// stay at their relative slots in the stored middle list.
  @visibleForTesting
  static List<String> orderAfterMiddleReorder({
    required SidebarLayout layout,
    required List<String> visibleMiddleIds,
    required int oldIndex,
    required int newIndex,
    required bool downloadSupported,
  }) {
    var adjustedNewIndex = newIndex;
    if (adjustedNewIndex > oldIndex) adjustedNewIndex -= 1;

    final reorderedVisible = List<String>.from(visibleMiddleIds);
    final moved = reorderedVisible.removeAt(oldIndex);
    reorderedVisible.insert(adjustedNewIndex, moved);

    final reconciled =
        layout.reconcileLayout(downloadSupported: downloadSupported);
    final storedOrder = reconciled.order;

    final leadingIds =
        storedOrder.where((id) => _isLeadingAnchorId(id)).toList();
    final trailingIds =
        storedOrder.where((id) => _isTrailingAnchorId(id)).toList();
    final storedMiddleIds = storedOrder
        .where((id) => !_isLeadingAnchorId(id) && !_isTrailingAnchorId(id))
        .toList();

    final newMiddleIds = _mergeMiddleOrder(
      storedMiddleIds: storedMiddleIds,
      hiddenIds: reconciled.hidden,
      reorderedVisibleIds: reorderedVisible,
    );

    return [...leadingIds, ...newMiddleIds, ...trailingIds];
  }

  static bool _isLeadingAnchorId(String id) => id == 'search';

  static bool _isTrailingAnchorId(String id) =>
      id == 'downloads' || id == 'settings';

  static List<String> _mergeMiddleOrder({
    required List<String> storedMiddleIds,
    required Set<String> hiddenIds,
    required List<String> reorderedVisibleIds,
  }) {
    final result = <String>[];
    var visibleIndex = 0;

    for (final id in storedMiddleIds) {
      if (hiddenIds.contains(id)) {
        result.add(id);
      } else {
        result.add(reorderedVisibleIds[visibleIndex++]);
      }
    }

    return result;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncDestinations = ref.watch(sidebarDestinationsProvider);
    final destinations = switch (asyncDestinations) {
      AsyncData(:final value) => value,
      _ => SidebarLayout.defaults.reconcile(
          downloadSupported: isDownloadSupported,
        ),
    };

    final selected = selectedFor(destinations, location);
    final leading =
        destinations.where((d) => d.isAnchored && d.id == 'search').toList();
    final trailing =
        destinations.where((d) => d.isAnchored && d.id != 'search').toList();
    final middle = destinations.where((d) => !d.isAnchored).toList();

    final hasBackWidget = backToMydiaWidget != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (hasBackWidget)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: backToMydiaWidget!,
          ),
        Padding(
          padding: EdgeInsets.fromLTRB(20, hasBackWidget ? 16 : 20, 20, 24),
          child: Row(
            children: [
              const MydiaLogo(size: 36),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Mydia Player',
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                        letterSpacing: -0.5,
                      ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Column(
              children: [
                for (final destination in leading) ...[
                  _buildRow(
                    ref: ref,
                    destination: destination,
                    selected: selected,
                  ),
                  const SizedBox(height: 2),
                ],
                if (middle.isNotEmpty)
                  ReorderableListView.builder(
                    shrinkWrap: true,
                    buildDefaultDragHandles: false,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: middle.length,
                    onReorder: (oldIndex, newIndex) => _onReorder(
                      ref: ref,
                      middle: middle,
                      oldIndex: oldIndex,
                      newIndex: newIndex,
                    ),
                    itemBuilder: (context, index) {
                      final destination = middle[index];
                      return ReorderableDragStartListener(
                        key: ValueKey(destination.id),
                        index: index,
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 2),
                          child: _buildRow(
                            ref: ref,
                            destination: destination,
                            selected: selected,
                          ),
                        ),
                      );
                    },
                  ),
                SidebarRow(
                  icon: Icons.add_rounded,
                  selectedIcon: Icons.add_rounded,
                  label: '+ New filter',
                  isSelected: false,
                  onTap: () {},
                ),
                const Spacer(),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Divider(
                    height: 1,
                    color: AppColors.divider.withValues(alpha: 0.15),
                  ),
                ),
                const SizedBox(height: 8),
                for (final destination in trailing) ...[
                  _buildRow(
                    ref: ref,
                    destination: destination,
                    selected: selected,
                  ),
                  const SizedBox(height: 2),
                ],
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      ],
    );
  }

  void _onReorder({
    required WidgetRef ref,
    required List<NavDestination> middle,
    required int oldIndex,
    required int newIndex,
  }) {
    final layout =
        ref.read(sidebarLayoutStoreProvider).get() ?? SidebarLayout.defaults;
    final visibleMiddleIds = middle.map((d) => d.id).toList();

    final newOrder = orderAfterMiddleReorder(
      layout: layout,
      visibleMiddleIds: visibleMiddleIds,
      oldIndex: oldIndex,
      newIndex: newIndex,
      downloadSupported: isDownloadSupported,
    );

    ref.read(sidebarLayoutControllerProvider).reorder(newOrder);
  }

  Widget _buildRow({
    required WidgetRef ref,
    required NavDestination destination,
    required NavDestination? selected,
  }) {
    final isSelected = selected?.id == destination.id;
    final isDisabled = isOffline && destination.id != 'downloads';
    final canCustomise = !destination.isAnchored;

    if (destination.id == 'settings') {
      return SettingsSidebarRow(
        isSelected: isSelected,
        isDisabled: isDisabled,
        onTap: () => onNavigate(destination.route),
      );
    }

    final isFilter = destination is FilterDestination;

    return SidebarRow(
      icon: destination.icon,
      selectedIcon: destination.selectedIcon,
      label: destination.label,
      isSelected: isSelected,
      isDisabled: isDisabled,
      onTap: () => onNavigate(destination.route),
      canCustomise: canCustomise,
      onHide: canCustomise
          ? () => ref.read(sidebarLayoutControllerProvider).hide(destination.id)
          : null,
      onEdit: isFilter ? () {} : null,
      onDelete: isFilter
          ? () => ref
              .read(sidebarLayoutControllerProvider)
              .deleteFilter(destination.id)
          : null,
    );
  }
}
