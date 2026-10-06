import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/downloads/download_service.dart' show isDownloadSupported;
import '../../../core/navigation/sidebar_layout_providers.dart';
import '../../../core/theme/colors.dart';
import '../../../domain/navigation/media_filter.dart';
import '../../../domain/navigation/nav_destination.dart';
import '../../../domain/navigation/sidebar_layout.dart';
import '../../screens/filter/filter_editor_sheet.dart';
import '../channel_badge.dart';
import '../mydia_logo.dart';
import '../../../domain/navigation/all_servers_locations.dart';
import 'all_servers_nav_list.dart';
import 'nav_badges.dart';
import 'sidebar_edit_bar.dart';
import 'sidebar_middle_list.dart';
import 'sidebar_row.dart';
import '../../../core/sources/media_source.dart' show SourceCapability;
import '../../../core/sources/sources_providers.dart';
import '../../../domain/navigation/source_nav.dart';
import 'current_source.dart';
import 'source_switcher.dart';

/// Shared sidebar navigation content used by both the desktop sidebar and the
/// mobile drawer.
class SidebarContent extends ConsumerWidget {
  const SidebarContent({
    super.key,
    required this.location,
    required this.onNavigate,
    required this.isOffline,
    this.onSwitchSource,
    this.backToMydiaWidget,
    this.selectedRowFocusNode,
  });

  final String location;
  final ValueChanged<String> onNavigate;

  /// Where a server switch navigates, when it should differ from
  /// [onNavigate]. The mobile drawer uses it to stay open across a switch.
  final ValueChanged<String>? onSwitchSource;
  final bool isOffline;
  final Widget? backToMydiaWidget;

  /// Node for the row matching the current route, so the shell can focus the
  /// sidebar deliberately when the viewer presses left at the content edge.
  ///
  /// Falls back to the first row the sidebar renders when the location matches
  /// no destination at all — see `_focusRowId` — because otherwise the node
  /// would attach to no row and the sidebar would be unreachable from a remote
  /// on the routes it does not list, such as a filter that has since been
  /// deleted.
  final FocusNode? selectedRowFocusNode;

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

  /// The destination whose row carries `selectedRowFocusNode`.
  ///
  /// Usually the selected row: that is the row a viewer already reads as "where
  /// I am" in the sidebar. The fallback exists because a location can match no
  /// destination at all — a filter the viewer deleted, a shared `/filter/<id>`
  /// link — and then no row would carry the node, leaving the shell with
  /// nothing to focus and the sidebar unreachable from the content with a
  /// D-pad, which is the defect the boundary exists to fix. The first row the
  /// sidebar renders is the predictable place for a left press to land on a
  /// screen the sidebar does not consider part of any destination.
  ///
  /// The order here mirrors the render order in [build] — anchors first, then
  /// the scrolling middle, then the remaining anchors. Anchors cannot be
  /// hidden, so only the middle list needs [middleIncludesHidden]; skipping
  /// hidden rows outside edit mode keeps the fallback on a row that is
  /// actually on screen, since [SidebarMiddleList] filters them out there.
  static String? _focusRowId({
    required NavDestination? selected,
    required List<NavDestination> leading,
    required List<SidebarEditRow> middle,
    required bool middleIncludesHidden,
    required List<NavDestination> trailing,
  }) {
    if (selected != null) return selected.id;
    if (leading.isNotEmpty) return leading.first.id;
    for (final row in middle) {
      if (middleIncludesHidden || !row.hidden) return row.destination.id;
    }
    if (trailing.isNotEmpty) return trailing.first.id;
    return null;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final editing = ref.watch(sidebarEditModeProvider);

    final asyncDestinations = ref.watch(sidebarDestinationsProvider);
    final destinations = switch (asyncDestinations) {
      AsyncData(:final value) => value,
      _ => SidebarLayout.defaults.reconcile(
          downloadSupported: isDownloadSupported,
        ),
    };

    final asyncEditRows = ref.watch(sidebarEditRowsProvider);
    final editRows = switch (asyncEditRows) {
      AsyncData(:final value) => value,
      _ => SidebarLayout.defaults.reconcileForEditing(
          downloadSupported: isDownloadSupported,
        ),
    };

    final selected = selectedFor(destinations, location);
    final leading =
        destinations.where((d) => d.isAnchored && d.id == 'search').toList();
    final trailing =
        destinations.where((d) => d.isAnchored && d.id != 'search').toList();
    final focusRowId = _focusRowId(
      selected: selected,
      leading: leading,
      middle: editRows,
      middleIncludesHidden: editing,
      trailing: trailing,
    );

    final hasBackWidget = backToMydiaWidget != null;
    final allServers = isAllServersLocation(location);
    // All servers replaces the layout, so it cannot be edited.
    final ownsNav = allServers;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (hasBackWidget)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: backToMydiaWidget!,
          ),
        Padding(
          padding: EdgeInsets.fromLTRB(20, hasBackWidget ? 16 : 20, 12, 16),
          child: Row(
            children: [
              const MydiaLogo(size: 36),
              const SizedBox(width: 12),
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        'Mydia Player',
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                        style:
                            Theme.of(context).textTheme.headlineSmall?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: -0.5,
                                ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    const ChannelBadge(),
                  ],
                ),
              ),
              if (!ownsNav)
                IconButton(
                  onPressed: () =>
                      ref.read(sidebarEditModeProvider.notifier).toggle(),
                  tooltip: 'Edit sidebar',
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                    Icons.edit_outlined,
                    size: 20,
                    color:
                        editing ? AppColors.primary : AppColors.textSecondary,
                  ),
                ),
            ],
          ),
        ),
        SourceSwitcher(
          location: location,
          onNavigate: onNavigate,
          onSwitchSource: onSwitchSource,
        ),
        if (editing && !ownsNav)
          SidebarEditBar(
            onDone: () => ref.read(sidebarEditModeProvider.notifier).exit(),
            onReset: () => _confirmReset(context, ref),
          ),
        if (allServers)
          Expanded(
            child: AllServersNavList(
              location: location,
              onNavigate: onNavigate,
              selectedRowFocusNode: selectedRowFocusNode,
            ),
          )
        else if (!editing)
          Expanded(
            child: _buildSourceNav(
              context: context,
              ref: ref,
              destinations: destinations,
            ),
          )
        else
          // Edit mode arranges the viewer's whole layout, hidden rows
          // included, so it renders the layout rather than one source's rows.
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Column(
                children: [
                  for (final destination in leading) ...[
                    _buildRow(
                      ref: ref,
                      context: context,
                      destination: destination,
                      selected: selected,
                      focusRowId: focusRowId,
                      isEditing: editing,
                    ),
                    const SizedBox(height: 2),
                  ],
                  Expanded(
                    child: SidebarMiddleList(
                      editing: editing,
                      rows: editRows,
                      buildRow: (row, {editingTrailing}) => _buildRow(
                        ref: ref,
                        context: context,
                        destination: row.destination,
                        selected: selected,
                        focusRowId: focusRowId,
                        isEditing: editing,
                        isHidden: row.hidden,
                        editingTrailing: editingTrailing,
                      ),
                      onReorder: (oldIndex, newIndex) => _onReorder(
                        ref: ref,
                        oldIndex: oldIndex,
                        newIndex: newIndex,
                      ),
                      onRestore: (id) =>
                          ref.read(sidebarLayoutControllerProvider).unhide(id),
                    ),
                  ),
                  if (!editing)
                    SidebarRow(
                      icon: Icons.add_rounded,
                      selectedIcon: Icons.add_rounded,
                      label: '+ New filter',
                      isSelected: false,
                      onTap: () => showFilterEditor(
                        context: context,
                        ref: ref,
                        initialFilter: MediaFilter.allMovies,
                      ),
                    ),
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
                      context: context,
                      destination: destination,
                      selected: selected,
                      focusRowId: focusRowId,
                      isEditing: editing,
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

  /// The rows for the source this location belongs to. Search and the app's
  /// own entries (Downloads, Settings) stay pinned around a scrolling middle,
  /// as they are in edit mode.
  Widget _buildSourceNav({
    required BuildContext context,
    required WidgetRef ref,
    required List<NavDestination> destinations,
  }) {
    final entries = ref.watch(sourceNavEntriesProvider(location));
    final source = ref.watch(currentSourceIdProvider(location));
    final canFilter = source != null &&
        (ref
                .watch(mediaSourceProvider(source))
                ?.capabilities
                .contains(SourceCapability.savedFilters) ??
            false);

    SourceNavEntry? selected;
    for (final entry in entries) {
      if (!entry.matches(location)) continue;
      if (selected == null || entry.route.length > selected.route.length) {
        selected = entry;
      }
    }
    // The shell's node goes on the selected row, else the first one, so a
    // remote can reach the sidebar from routes the entries do not list.
    final focusId = selected?.id ?? entries.firstOrNull?.id;

    Widget row(SourceNavEntry entry) {
      final destination =
          destinations.where((d) => d.id == entry.id).firstOrNull;
      final isSelected = selected?.id == entry.id;
      if (destination == null) {
        return SidebarRow(
          key: ValueKey('source-nav-${entry.id}'),
          focusNode: entry.id == focusId ? selectedRowFocusNode : null,
          icon: entry.icon,
          selectedIcon: entry.selectedIcon,
          label: entry.label,
          isSelected: isSelected,
          isDisabled: isOffline,
          onTap: () => onNavigate(entry.route),
        );
      }
      return _buildRow(
        ref: ref,
        context: context,
        destination: destination,
        selected: null,
        focusRowId: focusId,
        route: entry.route,
        isSelectedOverride: isSelected,
      );
    }

    final leading = entries.where((e) => e.anchored && e.id == 'search');
    final trailing = entries.where((e) => e.anchored && e.id != 'search');
    final middle = entries.where((e) => !e.anchored);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        children: [
          for (final entry in leading) ...[
            row(entry),
            const SizedBox(height: 2)
          ],
          Expanded(
            child: ListView(
              children: [
                for (final entry in middle) ...[
                  row(entry),
                  const SizedBox(height: 2),
                ],
              ],
            ),
          ),
          if (canFilter)
            SidebarRow(
              icon: Icons.add_rounded,
              selectedIcon: Icons.add_rounded,
              label: '+ New filter',
              isSelected: false,
              onTap: () => showFilterEditor(
                context: context,
                ref: ref,
                initialFilter: MediaFilter.allMovies,
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Divider(
              height: 1,
              color: AppColors.divider.withValues(alpha: 0.15),
            ),
          ),
          const SizedBox(height: 8),
          for (final entry in trailing) ...[
            row(entry),
            const SizedBox(height: 2)
          ],
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  void _onReorder({
    required WidgetRef ref,
    required int oldIndex,
    required int newIndex,
  }) {
    final layout =
        ref.read(sidebarLayoutStoreProvider).get() ?? SidebarLayout.defaults;

    final newOrder = layout.orderAfterReorder(
      oldIndex: oldIndex,
      newIndex: newIndex,
      downloadSupported: isDownloadSupported,
    );

    ref.read(sidebarLayoutControllerProvider).reorder(newOrder);
  }

  /// Confirms before resetting, because reset is the one destructive action in
  /// edit mode. It restores default order and unhides every row. Saved
  /// filters survive (see `SidebarLayoutController.resetToDefaults`) but
  /// return to the bottom of the list, which the copy says plainly.
  Future<void> _confirmReset(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.surfaceVariant,
        title: const Text('Reset sidebar?'),
        content: const Text(
          'Restores the default order and shows every hidden row. Saved '
          'filters are kept, but move to the bottom of the list.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );

    // The controller is stateless and keepAlive, so its Ref survives this
    // dialog's await; see sidebar_layout_providers.dart for why keepAlive is
    // load-bearing there. Reading it at the point of use mirrors onDelete
    // above and showFilterEditor's onSave, and the context.mounted guard
    // covers the SidebarContent-unmounted-during-the-dialog case.
    if ((confirmed ?? false) && context.mounted) {
      await ref.read(sidebarLayoutControllerProvider).resetToDefaults();
    }
  }

  Widget _buildRow({
    required WidgetRef ref,
    required BuildContext context,
    required NavDestination destination,
    required NavDestination? selected,
    required String? focusRowId,
    bool isEditing = false,
    bool isHidden = false,
    Widget? editingTrailing,
    // A source's rows navigate to the source's own route and carry their own
    // selection, so both override what the layout destination says.
    String? route,
    bool? isSelectedOverride,
  }) {
    final target = route ?? destination.route;
    final isSelected = isSelectedOverride ?? selected?.id == destination.id;
    final isDisabled = isOffline && destination.id != 'downloads';
    final canCustomise = !destination.isAnchored;

    // The row that carries the shell's node. Not the same test as `isSelected`:
    // see [_focusRowId].
    final carriesFocusNode = destination.id == focusRowId;

    // Anchors read as locked while editing so they do not look draggable.
    // They cannot move, and saying so is more honest than leaving them bare.
    final Widget? trailing = isEditing && !canCustomise
        ? const Icon(
            Icons.lock_outline_rounded,
            size: 17,
            color: AppColors.textDisabled,
          )
        : editingTrailing;

    if (destination.id == 'settings') {
      return SettingsSidebarRow(
        location: location,
        focusNode: carriesFocusNode ? selectedRowFocusNode : null,
        isSelected: isSelected,
        isDisabled: isDisabled,
        onTap: () => onNavigate(target),
        isEditing: isEditing,
        isHidden: isHidden,
        editingTrailing: trailing,
      );
    }

    if (destination is FilterDestination) {
      return SidebarRow(
        focusNode: carriesFocusNode ? selectedRowFocusNode : null,
        icon: destination.icon,
        selectedIcon: destination.selectedIcon,
        label: destination.label,
        isSelected: isSelected,
        isDisabled: isDisabled,
        onTap: () => onNavigate(target),
        canCustomise: canCustomise,
        onHide: canCustomise
            ? () =>
                ref.read(sidebarLayoutControllerProvider).hide(destination.id)
            : null,
        onEdit: () => showFilterEditor(
          context: context,
          ref: ref,
          initialFilter: destination.filter,
          editing: destination,
        ),
        onDelete: () async {
          await ref
              .read(sidebarLayoutControllerProvider)
              .deleteFilter(destination.id);
          if (context.mounted &&
              (location == target || location.startsWith('$target/'))) {
            context.go('/');
          }
        },
        isEditing: isEditing,
        isHidden: isHidden,
        editingTrailing: trailing,
      );
    }

    return SidebarRow(
      focusNode: carriesFocusNode ? selectedRowFocusNode : null,
      icon: destination.icon,
      selectedIcon: destination.selectedIcon,
      label: destination.label,
      isSelected: isSelected,
      isDisabled: isDisabled,
      onTap: () => onNavigate(target),
      canCustomise: canCustomise,
      onHide: canCustomise
          ? () => ref.read(sidebarLayoutControllerProvider).hide(destination.id)
          : null,
      isEditing: isEditing,
      isHidden: isHidden,
      editingTrailing: trailing,
    );
  }
}
