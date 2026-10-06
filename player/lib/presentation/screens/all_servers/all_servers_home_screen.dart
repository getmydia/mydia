/// The All servers home: Continue Watching and Recently Added from every
/// included server.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/layout/dock_insets.dart';
import '../../../core/sources/capabilities.dart';
import '../../../core/sources/mydia/bound_mydia.dart';
import '../../../core/sources/sources_providers.dart';
import '../../../domain/sources/item.dart';
import '../../../domain/sources/source_error.dart';
import '../../widgets/media_context_menu.dart';
import '../../widgets/toast/toaster.dart';
import '../sources/source_continue_watching_row.dart'
    show continueWatchingCaption;
import '../sources/source_error_view.dart';
import '../sources/source_poster_row.dart';
import 'all_servers_banner.dart';
import 'all_servers_cards.dart';
import 'all_servers_providers.dart';

class AllServersHomeScreen extends ConsumerWidget {
  const AllServersHomeScreen({super.key});

  void _refresh(WidgetRef ref) {
    ref.invalidate(allServersContinueWatchingProvider);
    ref.invalidate(allServersRecentlyAddedProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final resuming = ref.watch(allServersContinueWatchingProvider);
    final recent = ref.watch(allServersRecentlyAddedProvider);
    if (!resuming.hasValue || !recent.hasValue) {
      return const Center(child: CircularProgressIndicator());
    }
    final r = resuming.requireValue, n = recent.requireValue;
    final included = ref.watch(allServersNamesProvider);
    final continueItems = stillIncluded(included, r.value);
    final recentItems = stillIncluded(included, n.value);
    final everyServer = ref.watch(allServersSourcesProvider).length;
    final unavailable = {...r.unavailable, ...n.unavailable}.toList();
    // Zero included servers is nothing to show, not every server failing.
    if (everyServer > 0 && unavailable.length >= everyServer) {
      return SourceErrorView(
          error: const SourceException.unreachable(),
          onRetry: () => _refresh(ref));
    }
    return RefreshIndicator(
      onRefresh: () async => _refresh(ref),
      child: ListView(
        key: const Key('all-servers-home'),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.fromLTRB(0, 16, 0, DockInsets.bottomOf(context)),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
            child: Text('All servers',
                style: Theme.of(context).textTheme.headlineSmall),
          ),
          AllServersBanner(
              unavailable: unavailable, onRetry: () => _refresh(ref)),
          if (continueItems.isNotEmpty)
            SourcePosterRow(
              key: const Key('all-continue-watching'),
              title: 'Continue Watching',
              railId: 'all-continue',
              items: continueItems,
              posterFor: (context, item) => AllServersPoster(
                item: item,
                caption: continueWatchingCaption(item),
                onContextMenu: (c) => _menu(c, ref, item),
              ),
            ),
          if (recentItems.isNotEmpty)
            SourcePosterRow(
              key: const Key('all-recently-added'),
              title: 'Recently Added',
              railId: 'all-recent',
              items: recentItems,
              posterFor: (context, item) => AllServersPoster(item: item),
            ),
          if (continueItems.isEmpty && recentItems.isEmpty)
            const Padding(
              padding: EdgeInsets.all(48),
              child: Center(child: Text('Nothing to show yet.')),
            ),
        ],
      ),
    );
  }

  Future<void> _menu(BuildContext c, WidgetRef ref, ItemSummary item) async {
    final source = ref
        .read(allServersSourcesProvider)
        .where((s) => s.id == item.ref.sourceId)
        .firstOrNull;
    final cw = source?.as<ContinueWatching>();
    final removable = cw?.canRemoveFromContinueWatching(item) ?? false;
    final position = popupPositionBelow(c);
    if (position == null) return;
    final choice = await showMenu<String>(
      context: c,
      position: position,
      items: [
        const PopupMenuItem(
            key: Key('all-continue-details'),
            value: 'details',
            child: Text('Details')),
        if (removable)
          const PopupMenuItem(
              key: Key('all-continue-remove'),
              value: 'remove',
              child: Text('Remove from Continue Watching')),
      ],
    );
    if (choice == null || !c.mounted) return;
    switch (choice) {
      case 'details':
        await c.push(
            allServersItemLocation(item.ref, ref.read(boundSourceIdProvider)));
      case 'remove':
        if (cw == null) return;
        final toaster = Toaster.of(c);
        try {
          await cw.removeFromContinueWatching(item.ref);
        } catch (e) {
          toaster.show(
            e is SourceException
                ? e.viewerMessage
                : 'Could not remove this title.',
            kind: ToastKind.error,
          );
          return;
        }
        ref.invalidate(allServersContinueWatchingProvider);
    }
  }
}
