import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
// Conditional import for web URL handling
import 'web_url_stub.dart' if (dart.library.js_interop) 'web_url.dart'
    as web_url;
import 'source_detail_routes.dart';
import '../sources/media_source.dart' show MediaSource;
import '../sources/source.dart';
import '../sources/lock/source_lock_controller.dart';
import '../sources/sources_providers.dart';
import '../sources/mydia/bound_mydia.dart';
import '../../domain/sources/library.dart';
import '../../presentation/screens/sources/unlock_screen.dart';
import '../../presentation/screens/sources/source_player_route.dart';
import '../../presentation/screens/sources/source_search_screen.dart';
import '../../presentation/screens/sources/source_home_screen.dart';
import '../../presentation/screens/all_servers/all_servers_cards.dart';
import '../../presentation/screens/all_servers/all_servers_grid_screen.dart';
import '../../presentation/screens/all_servers/all_servers_home_screen.dart';
import '../../presentation/screens/all_servers/all_servers_search_screen.dart';
import '../../presentation/screens/sources/source_library_screen.dart';
import '../../presentation/screens/detail/detail_links.dart' show SourceListing;
import '../../presentation/screens/calendar/calendar_screen.dart';
import '../../presentation/screens/collections/collection_detail_screen.dart';
import '../../presentation/screens/collections/collections_screen.dart';
import '../../presentation/screens/continue_watching/continue_watching_screen.dart';
import '../../presentation/screens/favorites/favorites_screen.dart';
import '../../presentation/screens/recently_added/recently_added_screen.dart';
import '../../presentation/screens/unwatched/unwatched_screen.dart';
import '../../presentation/screens/login_screen.dart';
import '../../presentation/screens/sources/add_source_screen.dart';
import '../../presentation/screens/sources/manage_sources_screen.dart';
import '../../presentation/screens/sources/plex_sign_in_screen.dart';
import '../../presentation/screens/sources/jellyfin_connect_screen.dart';
import '../../presentation/screens/sources/stash_connect_screen.dart';
import '../../presentation/screens/settings/settings_screen.dart';
import '../../presentation/screens/settings/diagnostics_screen.dart';
import '../../presentation/screens/player/queue_player_screen.dart';
import '../../presentation/screens/downloads/downloads_screen.dart';
import '../../presentation/widgets/app_shell.dart';
import '../graphql/graphql_provider.dart';
import 'navigator_keys.dart';
import 'legacy_routes.dart';

part 'app_router.g.dart';

/// Global key for the navigator used by the app shell
final _shellNavigatorKey = GlobalKey<NavigatorState>();

/// Simple ChangeNotifier to trigger GoRouter refreshes.
/// What the redirect decides on is read directly from the providers in the
/// redirect callback.
class _RouterRefreshNotifier extends ChangeNotifier {
  void refresh() {
    debugPrint('[AppRouter] _RouterRefreshNotifier.refresh() called');
    notifyListeners();
  }
}

/// The `PlayerScreen` constructor arguments encoded in `/player/:type/:id`'s
/// query string.
///
/// Extracted out of the `GoRoute`'s `builder` so a test can assert this
/// mapping directly against a plain [Uri] — `builder` itself needs a live
/// `BuildContext`/`GoRouterState`, which is exactly the seam this avoids.
/// This is the other half of the contract `resolveLoadContentRoute`
/// (`app.dart`) writes to: whatever that function puts in a route's query
/// string, this reads back out.
@immutable
class PlayerRouteParams {
  final String? fileId;
  final String? title;
  final String? showId;
  final int? seasonNumber;
  final int? resumeSeconds;
  final String? audioTrack;
  final String? subtitleTrack;
  final bool autoplay;

  const PlayerRouteParams({
    this.fileId,
    this.title,
    this.showId,
    this.seasonNumber,
    this.resumeSeconds,
    this.audioTrack,
    this.subtitleTrack,
    this.autoplay = true,
  });

  factory PlayerRouteParams.fromUri(Uri uri) {
    final query = uri.queryParameters;
    return PlayerRouteParams(
      fileId: query['fileId'],
      title: query['title'],
      showId: query['showId'],
      seasonNumber: int.tryParse(query['seasonNumber'] ?? ''),
      resumeSeconds: int.tryParse(query['resume'] ?? ''),
      audioTrack: query['audioTrack'],
      subtitleTrack: query['subtitleTrack'],
      // Absent means the default (true, i.e. play). Only a remote
      // `LoadContent` with `autoplay: false` ever sends this param.
      autoplay: query['autoplay'] != 'false',
    );
  }
}

SourceId? _sourceIdIn(String location) {
  if (!location.startsWith('/s/')) return null;
  final segment = location.substring(3).split('/').first;
  if (segment.isEmpty) return null;
  // matchedLocation stays percent-encoded; the route decodes it later.
  try {
    return SourceId(Uri.decodeComponent(segment));
  } on ArgumentError {
    return SourceId(segment);
  } on FormatException {
    return SourceId(segment);
  }
}

/// Builder for the unprefixed pre-instance routes. They stay registered so
/// go_router matches them, but `appRedirect` always moves them first.
Widget _legacyStub(BuildContext context, GoRouterState state) =>
    const SizedBox.shrink();

/// The listings every Mydia source shows: path, route name, screen. The paths
/// are `SourceListing.segment`.
final List<(String, String, Widget Function(SourceId))> _sourceListings = [
  (
    SourceListing.collections.segment,
    'source_collections',
    (id) => CollectionsScreen(sourceId: id)
  ),
  (
    SourceListing.calendar.segment,
    'source_calendar',
    (id) => CalendarScreen(sourceId: id)
  ),
  (
    SourceListing.favorites.segment,
    'source_favorites',
    (id) => FavoritesScreen(sourceId: id)
  ),
  (
    SourceListing.unwatched.segment,
    'source_unwatched',
    (id) => UnwatchedScreen(sourceId: id)
  ),
  (
    SourceListing.recentlyAdded.segment,
    'source_recently_added',
    (id) => RecentlyAddedScreen(sourceId: id)
  ),
  (
    SourceListing.continueWatching.segment,
    'source_continue_watching',
    (id) => ContinueWatchingScreen(sourceId: id)
  ),
];

/// The `/all*` redirect, held while saved sources are still loading so a
/// cold start does not read an empty set and bounce to `/`. The router
/// refreshes when loading ends.
String? allServersRouteRedirect({
  required bool sourcesLoading,
  required List<MediaSource> included,
}) =>
    sourcesLoading ? null : allServersRedirect(included);

/// Where `/sources/add/mydia` redirects: an instance-hosted web player that
/// already has its Mydia account cannot add servers of its own. With no
/// account yet it must stay, or sign-in would loop through `/login`.
String? addMydiaRouteRedirect({
  required bool hasMydia,
  bool? instanceHostedWeb,
}) =>
    (instanceHostedWeb ?? isInstanceHostedWeb) && hasMydia ? '/' : null;

/// Where the router sends [location], or null to stay. Pure, so the rules
/// are testable without a router.
String? appRedirect({
  required String location,
  required bool sourcesLoading,
  required List<Source> sources,
  Set<SourceId> gated = const {},
  String? fullLocation,
  String? Function(Uri uri)? legacy,
}) {
  // A locked or hidden source opens only after unlocking. Same screen for
  // both, so a deep link never confirms that a hidden source exists.
  final target = _sourceIdIn(location);
  if (target != null && gated.contains(target)) {
    return unlockLocation(fullLocation ?? location);
  }
  // Held while loading: the instance ids a legacy location maps to are not
  // known yet. The router refreshes when loading ends.
  if (sourcesLoading) return null;
  // Where the unprefixed pre-instance locations live now. A gated result
  // is gated on the next pass.
  final moved = legacy?.call(Uri.parse(fullLocation ?? location));
  if (moved != null) return moved;

  final isUnlockRoute = location == '/unlock';

  final isLoginRoute = location == '/login';
  // Reached from the login screen's "Connect another server instead" and
  // "Show hidden servers" (Manage servers, after the unlock screen).
  final isSignedOutSourcesRoute = location == '/sources/add' ||
      location.startsWith('/sources/add/') ||
      location == '/sources/manage';

  // With any one source the app is usable; `/` has already moved to the
  // active one. With none, the only place to go is add-a-server.
  if (sources.isEmpty &&
      !isLoginRoute &&
      !isUnlockRoute &&
      !isSignedOutSourcesRoute) {
    return '/sources/add';
  }
  return null;
}

@Riverpod(keepAlive: true)
GoRouter appRouter(Ref ref) {
  debugPrint('[AppRouter] Creating appRouter provider');

  // Simple notifier just to trigger GoRouter refreshes
  final refreshNotifier = _RouterRefreshNotifier();

  // Binding or removing the Mydia instance changes where the router lands.
  ref.listen(boundMydiaProvider, (_, __) => refreshNotifier.refresh());

  // A first third-party source (Plex, Jellyfin or Stash) makes the app usable without Mydia.
  ref.listen(thirdPartySourcesProvider, (_, __) => refreshNotifier.refresh());
  ref.listen(sourcesLoadingProvider, (_, __) => refreshNotifier.refresh());
  ref.listen(selectedSourceIdProvider, (_, __) => refreshNotifier.refresh());
  // Where an old unprefixed location lands depends on which instances exist.
  ref.listen(legacyMydiaSourceIdProvider, (_, __) => refreshNotifier.refresh());
  ref.listen(mydiaSourceIdsProvider, (_, __) => refreshNotifier.refresh());
  // A relock while a gated screen is open sends it to /unlock.
  ref.listen(gatedSourceIdsProvider, (_, __) => refreshNotifier.refresh());

  // Dispose the notifier when the provider is disposed
  ref.onDispose(() {
    debugPrint('[AppRouter] Disposing appRouter provider');
    refreshNotifier.dispose();
  });

  // On web, read the initial route from the browser URL hash.
  // On native platforms, default to home.
  final initialLocation = web_url.getInitialRoute();
  debugPrint('[AppRouter] Initial location: $initialLocation');

  return GoRouter(
    navigatorKey: rootNavigatorKey,
    initialLocation: initialLocation,
    debugLogDiagnostics: true,
    refreshListenable: refreshNotifier,
    redirect: (context, state) {
      final target = appRedirect(
        location: state.matchedLocation,
        sourcesLoading: ref.read(sourcesLoadingProvider),
        sources: ref.read(thirdPartySourcesProvider),
        gated: ref.read(gatedSourceIdsProvider),
        fullLocation: state.uri.toString(),
        legacy: (uri) => legacyLocation(
          uri,
          legacy: ref.read(legacyMydiaSourceIdProvider),
          mydia: ref.read(mydiaSourceIdsProvider),
          active: ref.read(activeSourceIdProvider),
        ),
      );
      if (target != null) {
        debugPrint('[AppRouter] Redirecting ${state.matchedLocation} '
            'to $target');
      }
      return target;
    },
    routes: [
      // Login route - outside shell
      GoRoute(
        path: '/login',
        name: 'login',
        parentNavigatorKey: rootNavigatorKey,
        redirect: (context, state) => Uri(
          path: '/sources/add/mydia',
          query: state.uri.hasQuery ? state.uri.query : null,
        ).toString(),
        builder: (context, state) => const SizedBox.shrink(),
      ),
      GoRoute(
        path: '/unlock',
        name: 'unlock',
        parentNavigatorKey: rootNavigatorKey,
        builder: (context, state) =>
            UnlockScreen(next: state.uri.queryParameters['next']),
      ),
      GoRoute(
        path: '/sources/add',
        name: 'add_source',
        parentNavigatorKey: rootNavigatorKey,
        builder: (context, state) => const AddSourceScreen(),
      ),
      GoRoute(
        path: '/sources/add/plex',
        name: 'add_source_plex',
        parentNavigatorKey: rootNavigatorKey,
        builder: (context, state) => PlexSignInScreen(
          reauthAccountId: state.uri.queryParameters['account'],
        ),
      ),
      GoRoute(
        path: '/sources/add/stash',
        name: 'add_source_stash',
        parentNavigatorKey: rootNavigatorKey,
        builder: (context, state) => StashConnectScreen(
          reauthAccountId: state.uri.queryParameters['account'],
        ),
      ),
      GoRoute(
        path: '/sources/add/jellyfin',
        name: 'add_source_jellyfin',
        parentNavigatorKey: rootNavigatorKey,
        builder: (context, state) => JellyfinConnectScreen(
          reauthAccountId: state.uri.queryParameters['account'],
        ),
      ),
      GoRoute(
        path: '/sources/add/mydia',
        name: 'add_source_mydia',
        parentNavigatorKey: rootNavigatorKey,
        redirect: (context, state) => addMydiaRouteRedirect(
          hasMydia: ref.read(sourceRecordsProvider).value?.accounts.any(
                    (r) => r.account.kind == SourceKind.mydia,
                  ) ??
              false,
        ),
        builder: (context, state) => LoginScreen(
          reauthAccountId: state.uri.queryParameters['account'],
        ),
      ),

      GoRoute(
        path: '/sources/manage',
        name: 'manage_sources',
        parentNavigatorKey: rootNavigatorKey,
        builder: (context, state) => const ManageSourcesScreen(),
      ),
      // Where `/settings/devices` lands; the screen is the same list.
      GoRoute(
        path: '/sources/manage/:sourceId',
        name: 'manage_source',
        parentNavigatorKey: rootNavigatorKey,
        builder: (context, state) => const ManageSourcesScreen(),
      ),

      // Shell route for main app with bottom navigation
      ShellRoute(
        navigatorKey: _shellNavigatorKey,
        builder: (context, state, child) => AppShell(
          location: state.matchedLocation,
          child: child,
        ),
        routes: [
          GoRoute(
            path: '/',
            name: 'home',
            builder: _legacyStub,
          ),
          GoRoute(
            path: '/movies',
            name: 'movies_library',
            builder: _legacyStub,
          ),
          GoRoute(
            path: '/shows',
            name: 'shows_library',
            builder: _legacyStub,
          ),
          GoRoute(
            path: '/filter/:id',
            name: 'filter',
            builder: _legacyStub,
          ),
          GoRoute(
            path: '/favorites',
            name: 'favorites',
            builder: _legacyStub,
          ),
          GoRoute(
            path: '/recently-added',
            name: 'recently_added',
            builder: _legacyStub,
          ),
          GoRoute(
            path: '/continue-watching',
            name: 'continue_watching',
            builder: _legacyStub,
          ),
          GoRoute(
            path: '/unwatched',
            name: 'unwatched',
            builder: _legacyStub,
          ),
          GoRoute(
            path: '/calendar',
            name: 'calendar',
            builder: _legacyStub,
          ),
          GoRoute(
            path: '/collections',
            name: 'collections',
            builder: _legacyStub,
          ),
          GoRoute(
            path: '/downloads',
            name: 'downloads',
            builder: (context, state) => const DownloadsScreen(),
          ),
          GoRoute(
            path: '/settings',
            name: 'settings',
            builder: (context, state) => const SettingsScreen(),
          ),
          GoRoute(
            path: '/all',
            name: 'all_servers',
            redirect: (context, state) => allServersRouteRedirect(
              sourcesLoading: ref.read(sourcesLoadingProvider),
              included: ref.read(allServersSourcesProvider),
            ),
            builder: (context, state) => const AllServersHomeScreen(),
          ),
          GoRoute(
            path: '/all/movies',
            name: 'all_servers_movies',
            redirect: (context, state) => allServersRouteRedirect(
              sourcesLoading: ref.read(sourcesLoadingProvider),
              included: ref.read(allServersSourcesProvider),
            ),
            builder: (context, state) =>
                const AllServersGridScreen(kind: LibraryKind.movies),
          ),
          GoRoute(
            path: '/all/shows',
            name: 'all_servers_shows',
            redirect: (context, state) => allServersRouteRedirect(
              sourcesLoading: ref.read(sourcesLoadingProvider),
              included: ref.read(allServersSourcesProvider),
            ),
            builder: (context, state) =>
                const AllServersGridScreen(kind: LibraryKind.shows),
          ),
          GoRoute(
            path: '/all/search',
            name: 'all_servers_search',
            redirect: (context, state) => allServersRouteRedirect(
              sourcesLoading: ref.read(sourcesLoadingProvider),
              included: ref.read(allServersSourcesProvider),
            ),
            builder: (context, state) => const AllServersSearchScreen(),
          ),
          GoRoute(
            path: '/s/:sourceId',
            name: 'source_root',
            redirect: (context, state) => sourceRootRedirect(
              state.pathParameters['sourceId']!,
              ref.read(sourcesProvider),
            ),
            builder: (context, state) => SourceHomeScreen(
              sourceId: SourceId(state.pathParameters['sourceId']!),
            ),
          ),
          GoRoute(
            path: '/s/:sourceId/library/:libraryId',
            name: 'source_library',
            builder: (context, state) => SourceLibraryScreen(
              library: LibraryRef(
                sourceId: SourceId(state.pathParameters['sourceId']!),
                id: state.pathParameters['libraryId']!,
              ),
            ),
          ),
          sourceItemRoute(),
          GoRoute(
            path: '/s/:sourceId/search',
            name: 'source_search',
            builder: (context, state) => SourceSearchScreen(
              sourceId: SourceId(state.pathParameters['sourceId']!),
            ),
          ),
          for (final (path, name, build) in _sourceListings)
            GoRoute(
              path: '/s/:sourceId/$path',
              name: name,
              builder: (context, state) =>
                  build(SourceId(state.pathParameters['sourceId']!)),
            ),
          GoRoute(
            path: '/s/:sourceId/filter/:filterId',
            name: 'source_filter',
            builder: (context, state) => SourceRouteStub(
              sourceId: SourceId(state.pathParameters['sourceId']!),
              name: 'Filter',
            ),
          ),
          GoRoute(
            path: '/search',
            name: 'search',
            builder: _legacyStub,
          ),
        ],
      ),

      // Detail routes - outside shell
      GoRoute(
        path: '/settings/devices',
        name: 'devices',
        parentNavigatorKey: rootNavigatorKey,
        builder: _legacyStub,
      ),
      GoRoute(
        path: '/settings/diagnostics',
        name: 'diagnostics',
        parentNavigatorKey: rootNavigatorKey,
        builder: (context, state) => const DiagnosticsScreen(),
      ),
      GoRoute(
        path: '/collection/:id',
        name: 'collection_detail',
        parentNavigatorKey: rootNavigatorKey,
        builder: _legacyStub,
      ),
      // Full window, like the item detail routes: the screen owns the
      // title-bar band.
      GoRoute(
        path: '/s/:sourceId/collection/:collectionId',
        name: 'source_collection',
        parentNavigatorKey: rootNavigatorKey,
        builder: (context, state) => CollectionDetailScreen(
          sourceId: SourceId(state.pathParameters['sourceId']!),
          collectionId: state.pathParameters['collectionId']!,
        ),
      ),
      GoRoute(
        path: '/movie/:id',
        name: 'movie_detail',
        parentNavigatorKey: rootNavigatorKey,
        builder: _legacyStub,
      ),
      GoRoute(
        path: '/show/:id',
        name: 'show_detail',
        parentNavigatorKey: rootNavigatorKey,
        builder: _legacyStub,
      ),
      GoRoute(
        path: '/episode/:id',
        name: 'episode_detail',
        parentNavigatorKey: rootNavigatorKey,
        builder: _legacyStub,
      ),
      ...sourceDetailRoutes(),
      GoRoute(
        path: '/s/:sourceId/player/:itemId',
        name: 'source_player',
        parentNavigatorKey: rootNavigatorKey,
        builder: sourcePlayerRouteBuilder,
      ),
      // Queue player route for collection playback (must be before /player/:type/:id)
      GoRoute(
        path: '/player/queue',
        name: 'queue_player',
        parentNavigatorKey: rootNavigatorKey,
        builder: (context, state) {
          final itemsParam = state.uri.queryParameters['items'];

          if (itemsParam == null || itemsParam.isEmpty) {
            return Scaffold(
              body: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.error_outline,
                        size: 64, color: Colors.red),
                    const SizedBox(height: 16),
                    const Text('No items in queue'),
                    const SizedBox(height: 24),
                    ElevatedButton(
                      onPressed: () {
                        if (context.canPop()) {
                          context.pop();
                        } else {
                          context.go('/');
                        }
                      },
                      child: const Text('Go Back'),
                    ),
                  ],
                ),
              ),
            );
          }

          return QueuePlayerScreen(itemsParam: itemsParam);
        },
      ),
      // The pre-instance player route; `appRedirect` moves it under its source.
      GoRoute(
        path: '/player/:type/:id',
        name: 'player',
        parentNavigatorKey: rootNavigatorKey,
        builder: _legacyStub,
      ),
    ],
    errorBuilder: (context, state) => Scaffold(
      body: Center(
        child: Text('Page not found: ${state.uri}'),
      ),
    ),
  );
}
