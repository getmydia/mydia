import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/auth/auth_status.dart';
import '../../core/config/web_config.dart';
import '../../core/downloads/collection_sync_providers.dart';
import '../../core/downloads/collection_sync_service.dart';
import '../../core/downloads/download_service.dart' show isDownloadSupported;
import '../../core/graphql/graphql_provider.dart';
import '../../core/playback/playback_progress_providers.dart';
import '../screens/collections/collection_detail_controller.dart';
import '../../core/layout/breakpoints.dart';
import '../../core/theme/colors.dart';
import 'ambient_backdrop.dart';
import 'ambient_backdrop_provider.dart';
import 'cast_actions.dart';
import 'nav/bottom_nav.dart';
import 'nav/desktop_sidebar.dart';
import 'nav/mobile_drawer.dart';
import 'offline_banner.dart';

/// Modern app shell with adaptive navigation.
/// Shows sidebar on desktop (≥900px) and bottom nav on mobile.
class AppShell extends ConsumerStatefulWidget {
  final Widget child;
  final String location;

  /// Key for the mobile scaffold, used to open the drawer from inner screens.
  static final scaffoldKey = GlobalKey<ScaffoldState>();

  const AppShell({
    super.key,
    required this.child,
    required this.location,
  });

  /// Routes whose own screen already renders a [CastButton] in a real,
  /// always-visible app bar.
  ///
  /// [CastOverlayButton] exists only for screens with nowhere else to put the
  /// affordance — the desktop browse screens that suppress their app bar
  /// entirely (Home/Unwatched/Favorites/RecentlyAdded/Collections). Library,
  /// Downloads, Settings and Search all keep a real app bar on every
  /// platform, with their own action buttons (sort/view-toggle, cancel-all,
  /// clear, etc.) living in the exact top-right band this overlay paints
  /// into. Rendering the overlay there too would sit on top of — and
  /// intercept taps for — those existing buttons. Do not delete this check
  /// "to simplify": it is what keeps the overlay from colliding with a
  /// screen's own app bar the next time one grows an action.
  ///
  /// Public (rather than a private helper on [_AppShellState]) and annotated
  /// `@visibleForTesting` purely so a test can assert the routing decision
  /// directly, without reconstructing the shell's full provider graph.
  @visibleForTesting
  static bool hasOwnCastButton(String location) =>
      location.startsWith('/movies') ||
      location.startsWith('/shows') ||
      location.startsWith('/downloads') ||
      location.startsWith('/settings') ||
      location.startsWith('/search');

  /// Builds the shell's cast overlay for the desktop or mobile branch.
  ///
  /// [CastOverlayButton] wraps its child in its own `SafeArea`, which already
  /// consumes whatever the ambient `MediaQuery.padding.top` carries (the
  /// macOS title bar strip, on macOS windowed). `topInset` must therefore be
  /// the plain pre-strip offset — 12 below the desktop content, or below the
  /// mobile app bar — never `MediaQuery.paddingOf(context).top` folded in on
  /// top of that, or the button sits under the strip twice.
  ///
  /// Public (rather than inlined at each call site) and annotated
  /// `@visibleForTesting` so a test can exercise the exact value this shell
  /// computes for each branch directly, instead of re-declaring the numbers
  /// in a mirror that can silently drift from the real call sites.
  @visibleForTesting
  static Widget castOverlay({required bool isDesktop}) => CastOverlayButton(
        topInset: isDesktop ? 12 : kToolbarHeight + 8,
      );

  /// The gutter both the desktop and mobile branches wrap their main content
  /// column in: a `SafeArea` that consumes the ambient `MediaQuery.padding`
  /// on top only, leaving the sidebar/drawer chrome and bottom nav to handle
  /// their own edges.
  ///
  /// Public (rather than inlined at each call site) and annotated
  /// `@visibleForTesting`, mirroring [castOverlay], so a test can exercise
  /// the exact widget both branches build directly, instead of hand-rolling
  /// a `SafeArea` that can silently drift out of sync with the real call
  /// sites — the shell's actual gutter could lose its `SafeArea` entirely
  /// and a mirror-based test would stay green.
  @visibleForTesting
  static Widget contentGutter({required Widget child}) => SafeArea(
        top: true,
        bottom: false,
        left: false,
        right: false,
        child: child,
      );

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  AppLifecycleListener? _lifecycleListener;
  GoRouter? _router;
  DateTime? _lastAutoSyncTime;

  @override
  void initState() {
    super.initState();
    // Only add lifecycle listener on native platforms (not web)
    if (!kIsWeb) {
      _lifecycleListener = AppLifecycleListener(
        onResume: _onAppResume,
      );
      // Auto-sync collections after first frame
      if (isDownloadSupported) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _performCollectionAutoSync();
        });
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Listen to all route changes (including push/pop of detail screens)
    // to ensure the shell repaints when uncovered after a pop.
    final router = GoRouter.of(context);
    if (_router != router) {
      _router?.routerDelegate.removeListener(_onRouteChanged);
      _router = router;
      _router!.routerDelegate.addListener(_onRouteChanged);
    }
  }

  void _onRouteChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _router?.routerDelegate.removeListener(_onRouteChanged);
    _lifecycleListener?.dispose();
    super.dispose();
  }

  /// Called when app resumes from background.
  /// Checks connection status and triggers reconnection if needed.
  void _onAppResume() {
    debugPrint('[AppShell] App resumed from background');
    // Connection health checks are handled by the connection provider
    if (isDownloadSupported) {
      _performCollectionAutoSync();
    }
  }

  /// Auto-sync all collections that have sync enabled.
  /// Debounced to skip if already ran within the last 5 minutes.
  Future<void> _performCollectionAutoSync() async {
    // Debounce: skip if last sync was less than 5 minutes ago
    final now = DateTime.now();
    if (_lastAutoSyncTime != null &&
        now.difference(_lastAutoSyncTime!) < const Duration(minutes: 5)) {
      debugPrint('[AppShell] Skipping auto-sync (debounced)');
      return;
    }
    _lastAutoSyncTime = now;

    try {
      final syncConfigs = await ref.read(allSyncedCollectionsProvider.future);
      if (syncConfigs.isEmpty) return;

      debugPrint(
        '[AppShell] Auto-syncing ${syncConfigs.length} collection(s)',
      );

      int totalQueued = 0;
      for (final entry in syncConfigs.entries) {
        final collectionId = entry.key;
        final config = entry.value;
        final resolution = config['resolution'];
        if (resolution == null) continue;

        try {
          final items = await ref.read(
            collectionDetailControllerProvider(collectionId).future,
          );

          if (items.isEmpty) continue;

          final result = await syncCollectionItems(
            items: items,
            resolution: resolution,
            ref: ref,
          );
          totalQueued += result.totalQueued;

          if (result.hasNewDownloads) {
            debugPrint(
              '[AppShell] Auto-sync: ${config['name']} - '
              '${result.moviesQueued} movies, '
              '${result.episodesQueued} episodes queued',
            );
          }
        } catch (e) {
          debugPrint(
            '[AppShell] Auto-sync failed for ${config['name']}: $e',
          );
        }
      }

      if (totalQueued > 0 && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.sync_rounded, color: Colors.white, size: 20),
                const SizedBox(width: 12),
                Text(
                  'Auto-sync: queued $totalQueued new item${totalQueued != 1 ? 's' : ''} for download',
                ),
              ],
            ),
            backgroundColor: AppColors.primary,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      debugPrint('[AppShell] Auto-sync error: $e');
    }
  }

  /// Check if the app is currently in offline mode
  bool _isOfflineMode() {
    final authState = ref.watch(authStateProvider);
    return authState.maybeWhen(
      data: (status) => status == AuthStatus.offlineMode,
      orElse: () => false,
    );
  }

  /// Show a snackbar when a disabled nav item is tapped in offline mode
  void _showOfflineSnackbar() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Connect to server to access this'),
        backgroundColor: AppColors.surfaceVariant,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
      ),
    );
  }

  void _navigateTo(String route) {
    if (_isOfflineMode() && route != '/downloads') {
      _showOfflineSnackbar();
      return;
    }
    context.go(route);
  }

  @override
  Widget build(BuildContext context) {
    final location = widget.location;
    final showBackToMydia = isEmbedMode;
    final isOffline = _isOfflineMode();

    // Keeps the offline-to-online progress flush alive for the whole app
    // session: AppShell mounts for every reachable route before the
    // immersive player (which renders outside this shell) can be reached,
    // so watching it once here is enough for the underlying provider —
    // not autoDispose — to keep listening for the rest of the session.
    ref.watch(progressFlushProvider);
    // Use MediaQuery instead of LayoutBuilder to determine layout.
    // LayoutBuilder defers building to the layout phase, which can prevent
    // proper repaint propagation on mobile when combined with GlobalKey
    // on the Scaffold (causing the "stuck navigation" bug).
    final isDesktop = Breakpoints.isDesktop(context);
    final showCastOverlay = !AppShell.hasOwnCastButton(location);

    // Shell-level ambient backdrop, fed by the active browse screen. Sits behind
    // the (now transparent) in-shell Scaffolds for all browse screens (plan U5).
    final backdropSource = ref.watch(ambientBackdropControllerProvider);
    final backdrop = AmbientBackdrop(
      imageUrl: backdropSource.imageUrl,
      id: backdropSource.id,
    );

    if (isDesktop) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        body: Stack(
          children: [
            Positioned.fill(child: backdrop),
            Row(
              children: [
                DesktopSidebar(
                  location: location,
                  onNavigate: _navigateTo,
                  showBackToMydia: showBackToMydia,
                  isOffline: isOffline,
                ),
                Expanded(
                  child: AppShell.contentGutter(
                    child: Column(
                      children: [
                        if (isOffline) const OfflineBanner(),
                        Expanded(child: widget.child),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            if (showCastOverlay) AppShell.castOverlay(isDesktop: true),
          ],
        ),
      );
    }

    return Scaffold(
      key: AppShell.scaffoldKey,
      backgroundColor: Colors.transparent,
      extendBody: true,
      drawer: MobileDrawer(
        location: location,
        onNavigate: (route) {
          Navigator.of(context).pop();
          _navigateTo(route);
        },
        showBackToMydia: showBackToMydia,
        isOffline: isOffline,
      ),
      body: Stack(
        children: [
          Positioned.fill(child: backdrop),
          AppShell.contentGutter(
            child: Column(
              children: [
                if (isOffline) const OfflineBanner(),
                Expanded(child: widget.child),
              ],
            ),
          ),
          if (showCastOverlay) AppShell.castOverlay(isDesktop: false),
        ],
      ),
      bottomNavigationBar: BottomNav(
        location: location,
        onNavigate: _navigateTo,
        isOffline: isOffline,
        showBackToMydia: showBackToMydia,
      ),
    );
  }
}
