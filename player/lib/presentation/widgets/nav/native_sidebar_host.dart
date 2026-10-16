/// The iPad's native sidebar, driven from the shell.
///
/// Builds the sidebar from `sourceNavEntriesProvider(location)`, the list
/// `SidebarContent` renders, sends it on every build (the channel drops
/// repeats), and turns native taps back into the Flutter sidebar's actions.
/// Draws nothing but an invisible anchor for the source picker's popover.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/web_config.dart';
import '../../../core/platform/native_sidebar_state.dart';
import '../../../core/platform/native_tab_bar_channel.dart';
import '../../../core/sources/media_source.dart' show SourceCapability;
import '../../../core/sources/sources_providers.dart';
import '../../../domain/navigation/all_servers_locations.dart';
import '../../../domain/navigation/media_filter.dart';
import '../../screens/detail/detail_links.dart';
import '../../screens/filter/filter_editor_sheet.dart';
import 'current_source.dart';
import 'native_sidebar.dart';
import 'native_tab_bar.dart';
import 'sidebar_edit_sheet.dart';
import 'source_switcher.dart';

class NativeSidebarHost extends ConsumerStatefulWidget {
  const NativeSidebarHost({
    super.key,
    required this.location,
    required this.onNavigate,
    required this.visible,
    required this.isOffline,
    this.showBackToMydia = false,
    this.settingsBadge,
    this.onBackToMydia = navigateToMydiaApp,
  });

  final String location;
  final ValueChanged<String> onNavigate;
  final bool visible;
  final bool isOffline;
  final bool showBackToMydia;
  final String? settingsBadge;
  final VoidCallback onBackToMydia;

  @override
  ConsumerState<NativeSidebarHost> createState() => _NativeSidebarHostState();
}

class _NativeSidebarHostState extends ConsumerState<NativeSidebarHost> {
  late final NativeTabBarChannel _channel =
      ref.read(nativeTabBarChannelProvider);
  final GlobalKey _anchorKey = GlobalKey();
  StreamSubscription<NativeTabBarEvent>? _events;

  @override
  void initState() {
    super.initState();
    _events = _channel.events.listen(_onEvent);
  }

  @override
  void dispose() {
    unawaited(_events?.cancel());
    unawaited(_channel.setVisible(false));
    super.dispose();
  }

  void _onEvent(NativeTabBarEvent event) {
    if (event is NativeTabSelected && mounted) _onSelected(event.id);
  }

  void _onSelected(String id) {
    final location = widget.location;
    switch (id) {
      case kMydiaBackTabId:
        widget.onBackToMydia();
      case kSourceHeaderId:
        final current = currentSwitcherSource(ref, location);
        final anchor = _anchorKey.currentContext;
        if (current != null && anchor != null) {
          unawaited(openSourcePicker(
            anchor,
            ref,
            location: location,
            current: current,
            onNavigate: widget.onNavigate,
          ));
        }
      case kNewFilterId:
        unawaited(showFilterEditor(
          context: context,
          ref: ref,
          initialFilter: MediaFilter.allMovies,
        ));
      case kEditSidebarId:
        unawaited(showSidebarEditSheet(
          context: context,
          ref: ref,
          location: location,
        ));
      default:
        _openRow(id);
    }
  }

  /// A destination row navigates to its route; a server row selects that
  /// server and opens its home, as `AllServersServerRows` does.
  void _openRow(String id) {
    for (final entry in ref.read(sourceNavEntriesProvider(widget.location))) {
      if (entry.id == id) {
        widget.onNavigate(entry.route);
        return;
      }
    }
    for (final source in ref.read(allServersSourcesProvider)) {
      if (serverItemId(source.id) == id) {
        ref.read(selectedSourceIdProvider.notifier).select(source.id);
        widget.onNavigate(sourceHomeLocation(source.id));
        return;
      }
    }
    debugPrint('[NativeTabBar] ignored unknown sidebar item $id');
  }

  NativeSidebar _sidebar() {
    final location = widget.location;
    final allServers = isAllServersLocation(location);
    final source = ref.watch(currentSourceIdProvider(location));
    final canFilter = !allServers &&
        source != null &&
        (ref
                .watch(mediaSourceProvider(source))
                ?.capabilities
                .contains(SourceCapability.savedFilters) ??
            false);
    // currentSwitcherSource reads, so watch what it reads to rebuild the
    // payload when the server list or the active server changes.
    ref.watch(switchableSourcesProvider);
    ref.watch(activeSourceIdProvider);
    final current = currentSwitcherSource(ref, location);
    return nativeSidebarFor(
      entries: ref.watch(sourceNavEntriesProvider(location)),
      servers: allServers
          ? [
              for (final s in ref.watch(allServersSourcesProvider))
                (id: s.id, name: s.displayName),
            ]
          : const [],
      canFilter: canFilter,
      isOffline: widget.isOffline,
      showBackToMydia: widget.showBackToMydia,
      sourceHeader: current == null
          ? null
          : allServers
              ? 'All servers'
              : current.displayName,
      settingsBadge: widget.settingsBadge,
      // The macOS pane is a source list, which reads best with headings.
      grouped: defaultTargetPlatform == TargetPlatform.macOS,
    );
  }

  @override
  Widget build(BuildContext context) {
    final sidebar = _sidebar();
    final entries = ref.watch(sourceNavEntriesProvider(widget.location));
    final visible = widget.visible;
    final location = widget.location;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_channel.setSidebar(sidebar.toMap()));
      // Like the Flutter sidebar, a route with no row highlights none.
      final selected = selectedNativeSidebarId(entries, location);
      unawaited(selected == null
          ? _channel.clearSelection()
          : _channel.select(selected));
      unawaited(_channel.setVisible(visible));
    });
    // The picker's popover opens beside a narrow anchor, so this sits just
    // inside the sidebar's trailing edge, level with the header row.
    final leading = ref.watch(nativeSidebarInsetsProvider)?.leading ?? 0;
    return IgnorePointer(
      child: Stack(
        children: [
          Positioned(
            left: leading > 56 ? leading - 56 : 0,
            top: MediaQuery.paddingOf(context).top + 8,
            child: KeyedSubtree(
              key: const Key('native-sidebar-anchor'),
              child: SizedBox(key: _anchorKey, width: 48, height: 48),
            ),
          ),
        ],
      ),
    );
  }
}
