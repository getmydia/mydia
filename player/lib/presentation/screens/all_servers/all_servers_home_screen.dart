/// The All servers home: a hero, then Continue Watching, Recently Added
/// (movies, TV) and Favorites from every included server.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/layout/dock_insets.dart';
import '../../../core/sources/capabilities.dart';
import '../../../core/sources/sources_providers.dart';
import '../../../domain/merged/merged_result.dart';
import '../../../domain/sources/item.dart';
import '../../../domain/sources/source_error.dart';
import '../../widgets/media_context_menu.dart';
import '../../widgets/toast/toaster.dart';
import '../sources/source_continue_watching_row.dart'
    show continueWatchingCaption;
import '../sources/source_error_view.dart';
import '../sources/source_home_hero.dart';
import '../sources/source_poster_row.dart';
import 'all_servers_banner.dart';
import 'all_servers_cards.dart';
import 'all_servers_providers.dart';

class AllServersHomeScreen extends ConsumerWidget {
  const AllServersHomeScreen({super.key});

  void _refresh(WidgetRef ref) {
    ref.invalidate(allServersContinueWatchingProvider);
    ref.invalidate(allServersRecentlyAddedProvider);
    ref.invalidate(allServersFavoritesRowProvider);
  }

  /// A rail of merged posters; [result] supplies the "+N" copy counts.
  Widget _rail(
    BuildContext context, {
    required String key,
    required String railId,
    required String title,
    required String location,
    required List<ItemSummary> items,
    required MergedResult<List<ItemSummary>> result,
    String? Function(ItemSummary)? caption,
    Future<void> Function(BuildContext, ItemSummary)? menu,
  }) =>
      SourcePosterRow(
        key: Key(key),
        title: title,
        railId: railId,
        items: items,
        onTitleTap: () => context.push(location),
        posterFor: (context, item) => AllServersPoster(
          item: item,
          caption: caption?.call(item),
          onContextMenu: menu == null ? null : (c) => menu(c, item),
          extraCopies: result.extraCopies[item.ref] ?? 0,
        ),
      );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final resuming = ref.watch(allServersContinueWatchingProvider);
    final recent = ref.watch(allServersRecentlyAddedProvider);
    final favorites = ref.watch(allServersFavoritesRowProvider);
    if (!resuming.hasValue || !recent.hasValue) {
      return const Center(child: CircularProgressIndicator());
    }
    final r = resuming.requireValue, n = recent.requireValue;
    // Favorites loads in later; until then the rail is simply absent.
    final f = favorites.value;
    final included = ref.watch(allServersNamesProvider);
    final continueItems = stillIncluded(included, r.value);
    final recentItems = stillIncluded(included, n.value);
    final movieItems = recentItems.where(isMovieRow).toList();
    final showItems = recentItems.where((i) => !isMovieRow(i)).toList();
    final favoriteItems =
        f == null ? const <ItemSummary>[] : stillIncluded(included, f.value);
    final everyServer = ref.watch(allServersSourcesProvider).length;
    final unavailable =
        {...r.unavailable, ...n.unavailable, ...?f?.unavailable}.toList();
    // Zero included servers is nothing to show, not every server failing.
    if (everyServer > 0 && unavailable.length >= everyServer) {
      return SourceErrorView(
          error: const SourceException.unreachable(),
          onRetry: () => _refresh(ref));
    }
    final hero = continueItems.firstOrNull ?? movieItems.firstOrNull;
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
          if (hero != null)
            KeyedSubtree(
              key: const Key('all-home-hero'),
              child: SourceHomeHero(
                key: ValueKey('all-hero-${hero.ref.externalId}'),
                sourceId: hero.ref.sourceId,
                item: hero,
              ),
            ),
          if (continueItems.isNotEmpty)
            _rail(
              context,
              key: 'all-continue-watching',
              railId: 'all-continue',
              title: 'Continue Watching',
              location: allServersContinueWatchingLocation,
              items: continueItems,
              result: r,
              caption: continueWatchingCaption,
              menu: (c, item) => _menu(c, ref, item),
            ),
          if (movieItems.isNotEmpty)
            _rail(
              context,
              key: 'all-recent-movies',
              railId: 'all-recent-movies',
              title: 'Recently Added Movies',
              location: allServersRecentlyAddedLocation,
              items: movieItems,
              result: n,
            ),
          if (showItems.isNotEmpty)
            _rail(
              context,
              key: 'all-recent-shows',
              railId: 'all-recent-shows',
              title: 'Recently Added TV',
              location: '$allServersRecentlyAddedLocation?kind=shows',
              items: showItems,
              result: n,
            ),
          if (f != null && favoriteItems.isNotEmpty)
            _rail(
              context,
              key: 'all-favorites',
              railId: 'all-favorites',
              title: 'Favorites',
              location: allServersFavoritesLocation,
              items: favoriteItems,
              result: f,
            ),
          if (continueItems.isEmpty &&
              recentItems.isEmpty &&
              favoriteItems.isEmpty)
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
        await c.push(allServersItemLocation(item.ref));
      case 'remove':
        if (cw == null) return;
        final toaster = Toaster.of(c);
        try {
          await cw.removeFromContinueWatching(item.dismissRef);
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
