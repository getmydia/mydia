/// Home, for every included server or for one: a hero, Continue Watching,
/// Recently Added (movies, TV), Favorites, then a row per library.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/layout/dock_insets.dart';
import '../../../core/layout/window_chrome_inset.dart';
import '../../../core/sources/capabilities.dart';
import '../../../core/sources/sources_providers.dart';
import '../../../core/startup/startup_timeline.dart';
import '../../../domain/sources/item.dart';
import '../../../l10n/l10n.dart';
import '../../widgets/ambient_backdrop_provider.dart';
import '../../widgets/freshness_header.dart';
import '../../widgets/shell_rail_inset.dart';
import '../../widgets/window_chrome/window_title_row.dart';
import '../all_servers/all_servers_banner.dart';
import '../all_servers/all_servers_cards.dart';
import '../detail/detail_links.dart';
import '../sources/home_header.dart';
import '../sources/source_error_view.dart';
import '../sources/source_home_hero.dart';
import '../sources/source_poster_row.dart';
import 'home_continue_watching_row.dart';
import 'home_loading_skeleton.dart';
import 'home_rows.dart';
import 'home_rows_provider.dart';
import 'home_scope.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key, required this.scope});

  final HomeScope scope;

  /// The title bar that hosts the cast button and the window drag band.
  /// A `@visibleForTesting` seam so the cast alignment test needs no
  /// providers: this is the widget the screen puts in `appBar`.
  @visibleForTesting
  static PreferredSizeWidget header(
    BuildContext context, {
    Widget? mobileTitle,
    Widget? desktopTitle,
    VoidCallback? onSearch,
  }) =>
      homeHeader(context,
          mobileTitle: mobileTitle,
          desktopTitle: desktopTitle,
          onSearch: onSearch);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = ref.watch(homeRowsProvider(scope));
    if (!rows.loading) {
      StartupTimeline.app
        ..mark('home_first_data')
        ..logOnce();
    }
    // Nothing to feature, or nothing to show yet: the calm static backdrop.
    if (rows.loading || rows.hero == null) {
      publishBackdropSource(ref, BackdropSource.none);
    }
    // The title row draws into the window band on every platform, so the body
    // sits under `removeBand` or the band is counted twice.
    return WindowChromeInsets.removeBand(
      child: Builder(builder: (context) => _scaffold(context, ref, rows)),
    );
  }

  PreferredSizeWidget _bar(BuildContext context, WidgetRef ref) =>
      switch (scope) {
        AllServers() => header(
            context,
            mobileTitle: const HomeMydiaLockup(),
            desktopTitle: const HomeDesktopTitle(
                icon: Icons.dns_rounded, label: 'All servers'),
            onSearch: () => context.go(allServersSearchLocation),
          ),
        OneServer(:final id) => () {
            final source = ref.watch(mediaSourceProvider(id));
            return header(
              context,
              mobileTitle: HomeServerTitle(source?.displayName ?? 'Server'),
              onSearch: source?.as<Searchable>() == null
                  ? null
                  : () => context.push(sourceSearchLocation(id)),
            );
          }(),
      };

  /// Where a shared row's title goes: the merged listing for All servers,
  /// the server's own listing for one server.
  String _listing(SourceListing listing, String allLocation) => switch (scope) {
        AllServers() => allLocation,
        OneServer(:final id) => sourceListingLocation(id, listing),
      };

  Widget _scaffold(BuildContext context, WidgetRef ref, HomeRows rows) {
    // Read above the Scaffold: inside `extendBodyBehindAppBar` Flutter
    // rewrites padding.top to the bar's bottom edge (see BrowseScaffold).
    final chromeTop = freshnessTopInset(context,
        appBarHeight: WindowTitleRow.heightOf(context));
    final bar = _bar(context, ref);
    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: PreferredSize(
        preferredSize: bar.preferredSize,
        child: ShellPageInset(child: bar),
      ),
      body: _body(context, ref, rows, chromeTop),
    );
  }

  Widget _body(
      BuildContext context, WidgetRef ref, HomeRows rows, double chromeTop) {
    // The page spans the window so the hero's backdrop can run under the
    // rail; everything else sits beside it.
    final inset = ShellRailInset.of(context);
    final ids = rows.names.keys.toList();
    if (rows.loading) {
      // A hero and a landscape first rail, as the loaded page opens with.
      return ShellPageInset(
        child: HomeLoadingSkeleton(topInset: chromeTop + 16),
      );
    }
    if (rows.error case final error?) {
      return Padding(
        padding: EdgeInsets.only(top: chromeTop, left: inset),
        child: SourceErrorView(
          error: error,
          account: switch (scope) {
            OneServer(:final id) =>
              ref.watch(mediaSourceProvider(id))?.source.account,
            AllServers() => null,
          },
          onRetry: () => refreshHome(ref, ids),
        ),
      );
    }
    final hero = rows.hero;
    return Stack(
      children: [
        RefreshIndicator(
          edgeOffset: chromeTop,
          onRefresh: () => refreshHome(ref, ids),
          child: ListView(
            key: const Key('home-list'),
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.fromLTRB(
                inset, chromeTop + 16, 0, DockInsets.bottomOf(context)),
            children: [
              if (scope is AllServers)
                AllServersBanner(
                    unavailable: rows.unavailable,
                    onRetry: () => refreshHome(ref, ids)),
              if (hero != null)
                KeyedSubtree(
                  key: const Key('home-hero'),
                  child: SourceHomeHero(
                    key: ValueKey(
                        'home-hero-${hero.ref.sourceId.value}-${hero.ref.externalId}'),
                    sourceId: hero.ref.sourceId,
                    item: hero,
                    // Nothing sits above the hero but the list's own padding,
                    // so the backdrop runs up to the window top. A banner
                    // there keeps it.
                    bleedTop: rows.unavailable.isEmpty ? chromeTop + 16 : 0,
                  ),
                ),
              HomeContinueWatchingRow(
                rows: rows,
                onTitleTap: () => context.push(_listing(
                    SourceListing.continueWatching,
                    allServersContinueWatchingLocation)),
              ),
              if (rows.recentMovies.isNotEmpty)
                _rail(context, rows,
                    key: 'home-recent-movies',
                    title: 'Recently Added Movies',
                    items: rows.recentMovies,
                    location: _listing(SourceListing.recentlyAdded,
                        '$allServersRecentlyAddedLocation?kind=movies')),
              if (rows.recentShows.isNotEmpty)
                _rail(context, rows,
                    key: 'home-recent-shows',
                    title: 'Recently Added TV',
                    items: rows.recentShows,
                    location: _listing(SourceListing.recentlyAdded,
                        '$allServersRecentlyAddedLocation?kind=shows')),
              if (rows.favorites.isNotEmpty)
                _rail(context, rows,
                    key: 'home-favorites',
                    title: 'Favorites',
                    items: rows.favorites,
                    location: _listing(
                        SourceListing.favorites, allServersFavoritesLocation)),
              for (final row in rows.libraries)
                SourcePosterRow(
                  key: ValueKey(
                      'home-library-${row.library.sourceId.value}-${row.library.id}'),
                  title: row.title(context.l10n),
                  titleKey: Key(
                      'home-library-row-${row.library.sourceId.value}-${row.library.id}'),
                  railId:
                      'library-${row.library.sourceId.value}-${row.library.id}',
                  items: row.items,
                  onTitleTap: () =>
                      context.push(sourceLibraryLocation(row.library)),
                ),
              if (rows.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(48),
                  child: Center(child: Text('Nothing to show yet.')),
                ),
            ],
          ),
        ),
        // Overlaid, never a Column sibling: a refetch must not shove the
        // list (see BrowseScaffold's class doc).
        Positioned(
          top: 0,
          left: inset,
          right: 0,
          child: FreshnessHeader(
            topInset: chromeTop,
            queryKeys: homeQueryKeys(ids),
          ),
        ),
      ],
    );
  }

  /// A rail of merged posters. With two or more servers each poster names
  /// its server, with "+N" for the copies it stands in for.
  Widget _rail(
    BuildContext context,
    HomeRows rows, {
    required String key,
    required String title,
    required List<ItemSummary> items,
    required String location,
  }) =>
      SourcePosterRow(
        key: Key(key),
        title: title,
        railId: key,
        items: items,
        onTitleTap: () => context.push(location),
        posterFor: rows.labelled
            ? (context, item) => AllServersPoster(
                  item: item,
                  extraCopies: rows.extraCopies[item.ref] ?? 0,
                )
            : null,
      );
}
