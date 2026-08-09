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
                      leading: leading,
                      middle: middle,
                      trailing: trailing,
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
    required List<NavDestination> leading,
    required List<NavDestination> middle,
    required List<NavDestination> trailing,
    required int oldIndex,
    required int newIndex,
  }) {
    var adjustedNewIndex = newIndex;
    if (adjustedNewIndex > oldIndex) adjustedNewIndex -= 1;

    final middleIds = middle.map((d) => d.id).toList();
    final moved = middleIds.removeAt(oldIndex);
    middleIds.insert(adjustedNewIndex, moved);

    final newOrder = [
      ...leading.map((d) => d.id),
      ...middleIds,
      ...trailing.map((d) => d.id),
    ];

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
