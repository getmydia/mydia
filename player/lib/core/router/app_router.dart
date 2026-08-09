import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
// Conditional import for web URL handling
import 'web_url_stub.dart' if (dart.library.html) 'web_url.dart' as web_url;
import '../../presentation/screens/home_screen.dart';
import '../../presentation/screens/login_screen.dart';
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
      // Read auth state directly from the provider each time
      // This ensures we always get the latest state
      final authState = ref.read(authStateProvider);
      final authStatus = authState.maybeWhen(
        data: (status) => status,
        orElse: () => AuthStatus.unauthenticated,
      );
      final isLoading = authState.isLoading;
      final isLoginRoute = state.matchedLocation == '/login';
      final isDownloadsRoute = state.matchedLocation == '/downloads';
      final isPlayerRoute = state.matchedLocation.startsWith('/player');

      debugPrint(
          '[AppRouter] Redirect check: authStatus=$authStatus, isLoading=$isLoading, path=${state.matchedLocation}');

      // While loading, allow navigation to continue
      if (isLoading) {
        return null;
      }

      // Unauthenticated: must go to login
      if (authStatus == AuthStatus.unauthenticated && !isLoginRoute) {
        debugPrint('[AppRouter] Redirecting to /login (unauthenticated)');
        return '/login';
      }

      // Offline mode: only allow downloads and player routes
      if (authStatus == AuthStatus.offlineMode) {
        if (!isDownloadsRoute && !isPlayerRoute) {
          debugPrint('[AppRouter] Redirecting to /downloads (offline mode)');
          return '/downloads';
        }
      }

      // Authenticated on login: go home
      if (authStatus == AuthStatus.authenticated && isLoginRoute) {
        debugPrint(
            '[AppRouter] Redirecting to / (authenticated on login page)');
        return '/';
      }

      // No redirect needed
      return null;
    },
    routes: [
      // Login route - outside shell
      GoRoute(
        path: '/login',
        name: 'login',
        parentNavigatorKey: rootNavigatorKey,
        builder: (context, state) => const LoginScreen(),
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
            path: '/unwatched',
            name: 'unwatched',
            builder: (context, state) => const UnwatchedScreen(),
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
          final fileId = state.uri.queryParameters['fileId'];
          final title = state.uri.queryParameters['title'];
          final showId = state.uri.queryParameters['showId'];
          final seasonNumber =
              int.tryParse(state.uri.queryParameters['seasonNumber'] ?? '');
          final resumeSeconds =
              int.tryParse(state.uri.queryParameters['resume'] ?? '');

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
            title: title,
            showId: showId,
            seasonNumber: seasonNumber,
            resumeSeconds: resumeSeconds,
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
