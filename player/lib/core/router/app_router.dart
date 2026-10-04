import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
// Conditional import for web URL handling
import 'web_url_stub.dart' if (dart.library.js_interop) 'web_url.dart'
    as web_url;
import '../sources/source.dart';
import '../sources/lock/source_lock_controller.dart';
import '../sources/sources_providers.dart';
import '../../domain/sources/item.dart';
import '../../domain/sources/library.dart';
import '../../presentation/screens/sources/unlock_screen.dart';
import '../../presentation/screens/sources/source_item_screen.dart';
import '../../presentation/screens/sources/source_player_route.dart';
import '../../presentation/screens/sources/source_search_screen.dart';
import '../../presentation/screens/sources/source_home_screen.dart';
import '../../presentation/screens/sources/source_library_screen.dart';
import '../../presentation/screens/home_screen.dart';
import '../../presentation/screens/login_screen.dart';
import '../../presentation/screens/sources/add_source_screen.dart';
import '../../presentation/screens/sources/manage_sources_screen.dart';
import '../../presentation/screens/sources/plex_sign_in_screen.dart';
import '../../presentation/screens/sources/jellyfin_connect_screen.dart';
import '../../presentation/screens/sources/stash_connect_screen.dart';
import '../../presentation/screens/movie/movie_detail_screen.dart';
import '../../presentation/screens/show/show_detail_screen.dart';
import '../../presentation/screens/episode/episode_detail_screen.dart';
import '../../presentation/screens/filter/filter_screen.dart';
import '../../presentation/screens/library/library_screen.dart';
import '../../presentation/screens/library/library_controller.dart';
import '../../presentation/screens/settings/settings_screen.dart';
import '../../presentation/screens/settings/devices_screen.dart';
import '../../presentation/screens/settings/diagnostics_screen.dart';
import '../../presentation/screens/player/player_screen.dart';
import '../../presentation/screens/player/queue_player_screen.dart';
import '../../presentation/screens/downloads/downloads_screen.dart';
import '../../presentation/screens/favorites/favorites_screen.dart';
import '../../presentation/screens/recently_added/recently_added_screen.dart';
import '../../presentation/screens/unwatched/unwatched_screen.dart';
import '../../presentation/screens/continue_watching/continue_watching_screen.dart';
import '../../presentation/screens/calendar/calendar_screen.dart';
import '../../presentation/screens/collections/collections_screen.dart';
import '../../presentation/screens/collections/collection_detail_screen.dart';
import '../../presentation/screens/search/search_screen.dart';
import '../../domain/models/search_result.dart';
import '../../presentation/widgets/app_shell.dart';
import '../auth/auth_status.dart';
import '../graphql/graphql_provider.dart';
import 'navigator_keys.dart';

part 'app_router.g.dart';

/// Global key for the navigator used by the app shell
final _shellNavigatorKey = GlobalKey<NavigatorState>();

/// Simple ChangeNotifier to trigger GoRouter refreshes.
/// The actual auth state is read directly from the provider in the redirect callback.
class _AuthRefreshNotifier extends ChangeNotifier {
  void refresh() {
    debugPrint('[AppRouter] _AuthRefreshNotifier.refresh() called');
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

/// Where the router sends [location], or null to stay. Pure, so the rules
/// are testable without a router.
String? appRedirect({
  required AsyncValue<AuthStatus> auth,
  required String location,
  required bool sourcesLoading,
  required List<Source> thirdParty,
  SourceId? activeId,
  Set<SourceId> gated = const {},
  String? fullLocation,
}) {
  final authStatus = auth.maybeWhen(
    data: (status) => status,
    orElse: () => AuthStatus.unauthenticated,
  );
  if (auth.isLoading) return null;

  // A locked or hidden source opens only after unlocking. Same screen for
  // both, so a deep link never confirms that a hidden source exists.
  final target = _sourceIdIn(location);
  if (target != null && gated.contains(target)) {
    return unlockLocation(fullLocation ?? location);
  }
  final isUnlockRoute = location == '/unlock';

  final isLoginRoute = location == '/login';
  final isDownloadsRoute = location == '/downloads';
  final isPlayerRoute = location.startsWith('/player');
  // Reached from the login screen's "Connect another server instead" and
  // "Show hidden servers" (Manage servers, after the unlock screen).
  final isSignedOutSourcesRoute = location == '/sources/add' ||
      location.startsWith('/sources/add/') ||
      location == '/sources/manage';
  // Third-party server screens, and the screens that manage them.
  final isSourceRoute =
      location.startsWith('/s/') || location.startsWith('/sources');

  if (authStatus == AuthStatus.unauthenticated &&
      !isLoginRoute &&
      !isUnlockRoute &&
      !isSignedOutSourcesRoute) {
    // Usable with a Plex, Jellyfin or Stash server alone: land there, not on login.
    if (sourcesLoading) return null;
    if (thirdParty.isNotEmpty) {
      if (isSourceRoute) return null;
      // The remembered source when it still exists, else the first.
      final open = thirdParty.where((s) => !gated.contains(s.id));
      final landing =
          open.where((s) => s.id == activeId).firstOrNull ?? open.firstOrNull;
      if (landing == null) {
        return unlockLocation('/s/${thirdParty.first.id.value}');
      }
      return '/s/${landing.id.value}';
    }
    return '/login';
  }
  if (authStatus == AuthStatus.offlineMode &&
      !isDownloadsRoute &&
      !isUnlockRoute &&
      !isPlayerRoute &&
      !isSourceRoute) {
    return '/downloads';
  }
  if (authStatus == AuthStatus.authenticated && isLoginRoute) return '/';
  return null;
}

@Riverpod(keepAlive: true)
GoRouter appRouter(Ref ref) {
  debugPrint('[AppRouter] Creating appRouter provider');

  // Simple notifier just to trigger GoRouter refreshes
  final refreshNotifier = _AuthRefreshNotifier();

  // Listen to auth state changes and trigger router refresh
  ref.listen<AsyncValue<AuthStatus>>(authStateProvider, (previous, next) {
    debugPrint('[AppRouter] Auth state changed: $previous -> $next');
    refreshNotifier.refresh();
  });

  // A first third-party source (Plex, Jellyfin or Stash) makes the app usable without Mydia.
  ref.listen(thirdPartySourcesProvider, (_, __) => refreshNotifier.refresh());
  ref.listen(sourcesLoadingProvider, (_, __) => refreshNotifier.refresh());
  ref.listen(selectedSourceIdProvider, (_, __) => refreshNotifier.refresh());
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
        auth: ref.read(authStateProvider),
        location: state.matchedLocation,
        sourcesLoading: ref.read(sourcesLoadingProvider),
        thirdParty: ref.read(thirdPartySourcesProvider),
        activeId: ref.read(selectedSourceIdProvider),
        gated: ref.read(gatedSourceIdsProvider),
        fullLocation: state.uri.toString(),
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
        builder: (context, state) => const LoginScreen(),
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
        path: '/sources/manage',
        name: 'manage_sources',
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
            builder: (context, state) => const HomeScreen(),
          ),
          GoRoute(
            path: '/movies',
            name: 'movies_library',
            builder: (context, state) => const LibraryScreen(
              libraryType: LibraryType.movies,
            ),
          ),
          GoRoute(
            path: '/shows',
            name: 'shows_library',
            builder: (context, state) => const LibraryScreen(
              libraryType: LibraryType.tvShows,
            ),
          ),
          GoRoute(
            path: '/filter/:id',
            name: 'filter',
            builder: (context, state) =>
                FilterScreen(filterId: state.pathParameters['id']!),
          ),
          GoRoute(
            path: '/favorites',
            name: 'favorites',
            builder: (context, state) => const FavoritesScreen(),
          ),
          GoRoute(
            path: '/recently-added',
            name: 'recently_added',
            builder: (context, state) => const RecentlyAddedScreen(),
          ),
          GoRoute(
            path: '/continue-watching',
            name: 'continue_watching',
            builder: (context, state) => const ContinueWatchingScreen(),
          ),
          GoRoute(
            path: '/unwatched',
            name: 'unwatched',
            builder: (context, state) => const UnwatchedScreen(),
          ),
          GoRoute(
            path: '/calendar',
            name: 'calendar',
            builder: (context, state) => const CalendarScreen(),
          ),
          GoRoute(
            path: '/collections',
            name: 'collections',
            builder: (context, state) => const CollectionsScreen(),
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
          GoRoute(
            path: '/s/:sourceId/item/:kind/:itemId',
            name: 'source_item',
            builder: (context, state) => SourceItemScreen(
              item: ItemRef(
                sourceId: SourceId(state.pathParameters['sourceId']!),
                kind:
                    ItemKind.values.asNameMap()[state.pathParameters['kind']] ??
                        ItemKind.movie,
                externalId: state.pathParameters['itemId']!,
              ),
            ),
          ),
          GoRoute(
            path: '/s/:sourceId/search',
            name: 'source_search',
            builder: (context, state) => SourceSearchScreen(
              sourceId: SourceId(state.pathParameters['sourceId']!),
            ),
          ),
          GoRoute(
            path: '/search',
            name: 'search',
            builder: (context, state) => SearchScreen(
              initialQuery: state.uri.queryParameters['q'],
              initialType: SearchResultType.fromQueryValue(
                state.uri.queryParameters['type'],
              ),
            ),
          ),
        ],
      ),

      // Detail routes - outside shell
      GoRoute(
        path: '/settings/devices',
        name: 'devices',
        parentNavigatorKey: rootNavigatorKey,
        builder: (context, state) => const DevicesScreen(),
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
        builder: (context, state) {
          final id = state.pathParameters['id']!;
          return CollectionDetailScreen(id: id);
        },
      ),
      GoRoute(
        path: '/movie/:id',
        name: 'movie_detail',
        parentNavigatorKey: rootNavigatorKey,
        builder: (context, state) {
          final id = state.pathParameters['id']!;
          return MovieDetailScreen(id: id);
        },
      ),
      GoRoute(
        path: '/show/:id',
        name: 'show_detail',
        parentNavigatorKey: rootNavigatorKey,
        builder: (context, state) {
          final id = state.pathParameters['id']!;
          return ShowDetailScreen(id: id);
        },
      ),
      GoRoute(
        path: '/episode/:id',
        name: 'episode_detail',
        parentNavigatorKey: rootNavigatorKey,
        builder: (context, state) {
          final id = state.pathParameters['id']!;
          return EpisodeDetailScreen(id: id);
        },
      ),
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
      // Player route
      GoRoute(
        path: '/player/:type/:id',
        name: 'player',
        parentNavigatorKey: rootNavigatorKey,
        builder: (context, state) {
          final type = state.pathParameters['type']!;
          final id = state.pathParameters['id']!;
          final params = PlayerRouteParams.fromUri(state.uri);
          final fileId = params.fileId;

          if (fileId == null) {
            // If no fileId provided, show error
            return Scaffold(
              body: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.error_outline,
                        size: 64, color: Colors.red),
                    const SizedBox(height: 16),
                    const Text('No file selected for playback'),
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

          return PlayerScreen(
            mediaType: type,
            mediaId: id,
            fileId: fileId,
            title: params.title,
            showId: params.showId,
            seasonNumber: params.seasonNumber,
            resumeSeconds: params.resumeSeconds,
            audioTrack: params.audioTrack,
            subtitleTrack: params.subtitleTrack,
            autoplay: params.autoplay,
          );
        },
      ),
    ],
    errorBuilder: (context, state) => Scaffold(
      body: Center(
        child: Text('Page not found: ${state.uri}'),
      ),
    ),
  );
}
