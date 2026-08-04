import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/auth/auth_status.dart';
import '../../core/config/web_config.dart';
import '../../core/connection/connection_provider.dart';
import '../../core/downloads/collection_sync_providers.dart';
import '../../core/downloads/collection_sync_service.dart';
import '../../core/downloads/download_service.dart' show isDownloadSupported;
import '../../core/graphql/graphql_provider.dart';
import '../../core/playback/playback_progress_providers.dart';
import '../screens/collections/collection_detail_controller.dart';
import '../../core/layout/breakpoints.dart';
import '../../core/p2p/p2p_service.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/depth_tokens.dart';
import 'ambient_backdrop.dart';
import 'ambient_backdrop_provider.dart';
import 'cast_actions.dart';
import 'glass_surface.dart';
import 'offline_banner.dart';

/// Connection status badge for the settings icon.
/// Reflects actual P2P connection state with color-coded dot:
/// - Green: direct mode or P2P direct connection
/// - Blue: P2P mixed connection
/// - Orange: P2P relay connection
/// - Amber pulsing: P2P reconnecting (none)
class _ConnectionStatusBadge extends ConsumerWidget {
  const _ConnectionStatusBadge();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connectionState = ref.watch(connectionProvider);
    final isP2P = connectionState.isP2PMode;

    if (!isP2P) {
      return _buildDot(Colors.green, 'Direct connection');
    }

    final p2pStatus = ref.watch(p2pStatusNotifierProvider);
    final (color, tooltip) = switch (p2pStatus.peerConnectionType) {
      P2pConnectionType.direct => (Colors.green, 'P2P: Direct'),
      P2pConnectionType.mixed => (Colors.blue, 'P2P: Mixed'),
      P2pConnectionType.relay => (Colors.orange, 'P2P: Via relay'),
      P2pConnectionType.none => (Colors.amber, 'P2P: Reconnecting...'),
    };

    if (p2pStatus.peerConnectionType == P2pConnectionType.none &&
        p2pStatus.isInitialized) {
      return _PulsingDot(color: color, tooltip: tooltip);
    }

    return _buildDot(color, tooltip);
  }

  Widget _buildDot(Color color, String tooltip) {
    return Tooltip(
      message: tooltip,
      child: Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color,
          border: Border.all(
            color: AppColors.surface,
            width: 1.5,
          ),
          boxShadow: [
            BoxShadow(
              color: color.withValues(alpha: 0.4),
              blurRadius: 4,
              spreadRadius: 1,
            ),
          ],
        ),
      ),
    );
  }
}

/// An amber pulsing dot indicating reconnection in progress.
class _PulsingDot extends StatefulWidget {
  final Color color;
  final String tooltip;

  const _PulsingDot({required this.color, required this.tooltip});

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1200),
      vsync: this,
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          final opacity = 0.4 + (_controller.value * 0.6);
          return Opacity(
            opacity: opacity,
            child: Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: widget.color,
                border: Border.all(
                  color: AppColors.surface,
                  width: 1.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: widget.color.withValues(alpha: 0.4),
                    blurRadius: 4,
                    spreadRadius: 1,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

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

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  AppLifecycleListener? _lifecycleListener;
  GoRouter? _router;
  bool _homeExpanded = true;
  bool _libraryExpanded = false;
  DateTime? _lastAutoSyncTime;

  static bool _isHomeSection(String loc) =>
      loc == '/' ||
      loc.startsWith('/recently-added') ||
      loc.startsWith('/unwatched') ||
      loc.startsWith('/favorites') ||
      loc.startsWith('/collections');

  static bool _isLibrarySection(String loc) =>
      loc.startsWith('/movies') || loc.startsWith('/shows');

  @override
  void initState() {
    super.initState();
    _autoExpandForRoute(widget.location);
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
  void didUpdateWidget(covariant AppShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.location != widget.location) {
      _autoExpandForRoute(widget.location);
    }
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

  void _autoExpandForRoute(String location) {
    if (_isHomeSection(location) && !_homeExpanded) {
      setState(() => _homeExpanded = true);
    }
    if (_isLibrarySection(location) && !_libraryExpanded) {
      setState(() => _libraryExpanded = true);
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
                _DesktopSidebar(
                  location: location,
                  onNavigate: _navigateTo,
                  homeExpanded: _homeExpanded,
                  libraryExpanded: _libraryExpanded,
                  onToggleHome: () =>
                      setState(() => _homeExpanded = !_homeExpanded),
                  onToggleLibrary: () =>
                      setState(() => _libraryExpanded = !_libraryExpanded),
                  showBackToMydia: showBackToMydia,
                  isOffline: isOffline,
                ),
                Expanded(
                  child: SafeArea(
                    top: true,
                    bottom: false,
                    left: false,
                    right: false,
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
      drawer: _MobileDrawer(
        location: location,
        onNavigate: (route) {
          Navigator.of(context).pop();
          _navigateTo(route);
        },
        homeExpanded: _homeExpanded,
        libraryExpanded: _libraryExpanded,
        onToggleHome: () => setState(() => _homeExpanded = !_homeExpanded),
        onToggleLibrary: () =>
            setState(() => _libraryExpanded = !_libraryExpanded),
        showBackToMydia: showBackToMydia,
        isOffline: isOffline,
      ),
      body: Stack(
        children: [
          Positioned.fill(child: backdrop),
          SafeArea(
            top: true,
            bottom: false,
            left: false,
            right: false,
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
      bottomNavigationBar: _ModernBottomNav(
        location: location,
        onNavigate: _navigateTo,
        isOffline: isOffline,
        showBackToMydia: showBackToMydia,
      ),
    );
  }
}

/// Mydia squircle logo painted via CustomPainter.
class MydiaLogo extends StatelessWidget {
  final double size;

  const MydiaLogo({super.key, required this.size});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size(size, size),
      painter: const MydiaLogoPainter(),
    );
  }
}

class MydiaLogoPainter extends CustomPainter {
  const MydiaLogoPainter();

  /// The mark's fill. Deliberately neutral rather than [AppColors.primary]:
  /// the app icon and the Phoenix logo this mirrors are a fixed blue that the
  /// player's palette does not own, so a mark that tracked the accent would
  /// drift away from them on every repalette.
  static const Color markColor = AppColors.textPrimary;

  /// The inner cut-out, which reads as a hole through to the shell behind it.
  static const Color cutoutColor = AppColors.background;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width; // square
    final scale = s / 48.0; // SVG viewBox is 48x48

    // Outer squircle – mark fill
    final outerRect = RRect.fromLTRBR(
      1 * scale,
      1 * scale,
      47 * scale,
      47 * scale,
      Radius.circular(10 * scale),
    );
    canvas.drawRRect(outerRect, Paint()..color = markColor);

    // Inner squircle – background fill
    final innerRect = RRect.fromLTRBR(
      5 * scale,
      5 * scale,
      43 * scale,
      43 * scale,
      Radius.circular(7 * scale),
    );
    canvas.drawRRect(innerRect, Paint()..color = cutoutColor);

    // M letterform
    final mPath = Path()
      ..moveTo(12 * scale, 34 * scale)
      ..lineTo(12 * scale, 14 * scale)
      ..lineTo(18 * scale, 14 * scale)
      ..lineTo(24 * scale, 24 * scale)
      ..lineTo(30 * scale, 14 * scale)
      ..lineTo(36 * scale, 14 * scale)
      ..lineTo(36 * scale, 34 * scale)
      ..lineTo(31 * scale, 34 * scale)
      ..lineTo(31 * scale, 22 * scale)
      ..lineTo(25.5 * scale, 31 * scale)
      ..lineTo(22.5 * scale, 31 * scale)
      ..lineTo(17 * scale, 22 * scale)
      ..lineTo(17 * scale, 34 * scale)
      ..close();
    canvas.drawPath(mPath, Paint()..color = markColor);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Shared sidebar navigation content used by both the desktop sidebar and the
/// mobile drawer.
///
/// Public so the navigation destinations are unit-testable without mounting the
/// full shell's provider graph, matching [GlassSidebarPanel].
class SidebarContent extends StatelessWidget {
  final String location;
  final ValueChanged<String> onNavigate;
  final bool homeExpanded;
  final bool libraryExpanded;
  final VoidCallback onToggleHome;
  final VoidCallback onToggleLibrary;
  final bool isOffline;
  final double topPadding;
  final Widget? backToMydiaWidget;

  const SidebarContent({
    super.key,
    required this.location,
    required this.onNavigate,
    required this.homeExpanded,
    required this.libraryExpanded,
    required this.onToggleHome,
    required this.onToggleLibrary,
    required this.isOffline,
    this.topPadding = 0,
    this.backToMydiaWidget,
  });

  @override
  Widget build(BuildContext context) {
    final hasBackWidget = backToMydiaWidget != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(height: topPadding),
        // Back to Mydia link (shown in embed mode)
        if (hasBackWidget)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: backToMydiaWidget!,
          ),
        // Logo header
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

        // Navigation items
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Column(
              children: [
                // Home section (navigates to / AND toggles)
                _SidebarSection(
                  icon: Icons.home_outlined,
                  selectedIcon: Icons.home_rounded,
                  label: 'Home',
                  route: '/',
                  isExpanded: homeExpanded,
                  onToggleExpanded: onToggleHome,
                  isActive: _AppShellState._isHomeSection(location),
                  isDisabled: isOffline,
                  onNavigate: onNavigate,
                  location: location,
                  children: [
                    _SidebarItem(
                      icon: Icons.fiber_new_outlined,
                      selectedIcon: Icons.fiber_new_rounded,
                      label: 'Recently Added',
                      isSelected: location.startsWith('/recently-added'),
                      isDisabled: isOffline,
                      onTap: () => onNavigate('/recently-added'),
                    ),
                    const SizedBox(height: 2),
                    _SidebarItem(
                      icon: Icons.visibility_off_outlined,
                      selectedIcon: Icons.visibility_off_rounded,
                      label: 'Unwatched',
                      isSelected: location.startsWith('/unwatched'),
                      isDisabled: isOffline,
                      onTap: () => onNavigate('/unwatched'),
                    ),
                    const SizedBox(height: 2),
                    _SidebarItem(
                      icon: Icons.favorite_outline_rounded,
                      selectedIcon: Icons.favorite_rounded,
                      label: 'Favorites',
                      isSelected: location.startsWith('/favorites'),
                      isDisabled: isOffline,
                      onTap: () => onNavigate('/favorites'),
                    ),
                    const SizedBox(height: 2),
                    _SidebarItem(
                      icon: Icons.collections_bookmark_outlined,
                      selectedIcon: Icons.collections_bookmark_rounded,
                      label: 'Collections',
                      isSelected: location.startsWith('/collections'),
                      isDisabled: isOffline,
                      onTap: () => onNavigate('/collections'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                // Library section (toggle only, no route)
                _SidebarSection(
                  icon: Icons.video_library_outlined,
                  selectedIcon: Icons.video_library_rounded,
                  label: 'Library',
                  route: null,
                  isExpanded: libraryExpanded,
                  onToggleExpanded: onToggleLibrary,
                  isActive: _AppShellState._isLibrarySection(location),
                  isDisabled: isOffline,
                  onNavigate: onNavigate,
                  location: location,
                  children: [
                    _SidebarItem(
                      icon: Icons.movie_outlined,
                      selectedIcon: Icons.movie_rounded,
                      label: 'Movies',
                      isSelected: location.startsWith('/movies'),
                      isDisabled: isOffline,
                      onTap: () => onNavigate('/movies'),
                    ),
                    const SizedBox(height: 2),
                    _SidebarItem(
                      icon: Icons.tv_outlined,
                      selectedIcon: Icons.tv_rounded,
                      label: 'TV Shows',
                      isSelected: location.startsWith('/shows'),
                      isDisabled: isOffline,
                      onTap: () => onNavigate('/shows'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                _SidebarItem(
                  icon: Icons.search_outlined,
                  selectedIcon: Icons.search_rounded,
                  label: 'Search',
                  isSelected: location.startsWith('/search'),
                  isDisabled: isOffline,
                  onTap: () => onNavigate('/search'),
                ),
                if (isDownloadSupported) ...[
                  const SizedBox(height: 8),
                  _SidebarItem(
                    icon: Icons.download_outlined,
                    selectedIcon: Icons.download_rounded,
                    label: 'Downloads',
                    isSelected: location.startsWith('/downloads'),
                    onTap: () => onNavigate('/downloads'),
                  ),
                ],
                const Spacer(),
                // Subtle divider above Settings
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Divider(
                    height: 1,
                    color: AppColors.divider.withValues(alpha: 0.15),
                  ),
                ),
                const SizedBox(height: 8),
                _SettingsSidebarItem(
                  isSelected: location.startsWith('/settings'),
                  isDisabled: isOffline,
                  onTap: () => onNavigate('/settings'),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Desktop sidebar navigation with collapsible sections
class _DesktopSidebar extends StatelessWidget {
  final String location;
  final ValueChanged<String> onNavigate;
  final bool homeExpanded;
  final bool libraryExpanded;
  final VoidCallback onToggleHome;
  final VoidCallback onToggleLibrary;
  final bool showBackToMydia;
  final bool isOffline;

  const _DesktopSidebar({
    required this.location,
    required this.onNavigate,
    required this.homeExpanded,
    required this.libraryExpanded,
    required this.onToggleHome,
    required this.onToggleLibrary,
    this.showBackToMydia = false,
    this.isOffline = false,
  });

  @override
  Widget build(BuildContext context) {
    return GlassSidebarPanel(
      child: SafeArea(
        top: true,
        child: SidebarContent(
          location: location,
          onNavigate: onNavigate,
          homeExpanded: homeExpanded,
          libraryExpanded: libraryExpanded,
          onToggleHome: onToggleHome,
          onToggleLibrary: onToggleLibrary,
          isOffline: isOffline,
          topPadding: 0,
          backToMydiaWidget:
              showBackToMydia ? const _BackToMydiaButton() : null,
        ),
      ),
    );
  }
}

/// The desktop sidebar's glass chrome panel (R4/R6/R10).
///
/// A fixed-width, real-blur [GlassSurface] that sits over the shell ambient
/// backdrop and is therefore tinted by the artwork behind it (R5, verified in
/// U8). The light rim defines the right edge and the chrome shadow gives it
/// layered depth — replacing the prior flat `Container(color: background)` +
/// faint 1px border (R6). The chrome fill clears the R10 legibility floor so
/// nav labels stay readable over any backdrop.
///
/// Extracted as a public widget so the glass composition is unit-testable
/// without mounting the full shell's provider graph.
class GlassSidebarPanel extends StatelessWidget {
  final Widget child;

  const GlassSidebarPanel({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: Breakpoints.sidebarWidth,
      child: DecoratedBox(
        decoration: const BoxDecoration(boxShadow: DepthTokens.chrome),
        child: GlassSurface(
          blurSigma: DepthTokens.blurChrome,
          fillColor: AppColors.surface.withValues(
            alpha: DepthTokens.chromeFillOpacity,
          ),
          border: const Border(
            right: BorderSide(
              color: DepthTokens.rimColor,
              width: DepthTokens.rimWidth,
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// Collapsible sidebar section with animated chevron and children
class _SidebarSection extends StatefulWidget {
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final String? route;
  final bool isExpanded;
  final VoidCallback onToggleExpanded;
  final bool isActive;
  final bool isDisabled;
  final ValueChanged<String> onNavigate;
  final String location;
  final List<Widget> children;

  const _SidebarSection({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.route,
    required this.isExpanded,
    required this.onToggleExpanded,
    required this.isActive,
    required this.isDisabled,
    required this.onNavigate,
    required this.location,
    required this.children,
  });

  @override
  State<_SidebarSection> createState() => _SidebarSectionState();
}

class _SidebarSectionState extends State<_SidebarSection> {
  bool _isHovered = false;

  bool get _isHeaderSelected {
    // Header is selected only if the section route matches exactly
    if (widget.route == null) return false;
    return widget.location == widget.route;
  }

  @override
  Widget build(BuildContext context) {
    final isSelected = _isHeaderSelected && !widget.isDisabled;
    final hasActiveChild = widget.isActive && !_isHeaderSelected;
    final iconColor = widget.isDisabled
        ? AppColors.textDisabled
        : isSelected
            ? AppColors.primary
            : hasActiveChild
                ? AppColors.primary.withValues(alpha: 0.7)
                : _isHovered
                    ? AppColors.textPrimary
                    : AppColors.textSecondary;
    final textColor = widget.isDisabled
        ? AppColors.textDisabled
        : isSelected
            ? AppColors.textPrimary
            : hasActiveChild
                ? AppColors.textPrimary
                : _isHovered
                    ? AppColors.textPrimary
                    : AppColors.textSecondary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Section header
        MouseRegion(
          onEnter: (_) => setState(() => _isHovered = true),
          onExit: (_) => setState(() => _isHovered = false),
          cursor: widget.isDisabled
              ? SystemMouseCursors.forbidden
              : SystemMouseCursors.click,
          child: GestureDetector(
            onTap: () {
              widget.onToggleExpanded();
              if (widget.route != null) {
                widget.onNavigate(widget.route!);
              }
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOutCubic,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: widget.isDisabled
                    ? Colors.transparent
                    : isSelected
                        ? AppColors.primary.withValues(alpha: 0.12)
                        : _isHovered
                            ? AppColors.surfaceVariant.withValues(alpha: 0.3)
                            : Colors.transparent,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(
                    isSelected || hasActiveChild
                        ? widget.selectedIcon
                        : widget.icon,
                    size: 22,
                    color: iconColor,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      widget.label,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: isSelected || hasActiveChild
                            ? FontWeight.w600
                            : FontWeight.w500,
                        color: textColor,
                      ),
                    ),
                  ),
                  AnimatedRotation(
                    turns: widget.isExpanded ? 0 : -0.25,
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOutCubic,
                    child: Icon(
                      Icons.expand_more_rounded,
                      size: 20,
                      color: widget.isDisabled
                          ? AppColors.textDisabled
                          : AppColors.textSecondary.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        // Expandable children
        AnimatedSize(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: widget.isExpanded
              ? Padding(
                  padding: const EdgeInsets.only(left: 16, top: 2),
                  child: Column(
                    children: widget.children,
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }
}

/// Individual sidebar navigation item
class _SidebarItem extends StatefulWidget {
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool isSelected;
  final bool isDisabled;
  final VoidCallback onTap;
  final Widget? badge;

  const _SidebarItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.isSelected,
    required this.onTap,
    this.isDisabled = false,
    this.badge,
  });

  @override
  State<_SidebarItem> createState() => _SidebarItemState();
}

class _SidebarItemState extends State<_SidebarItem> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final isSelected = widget.isSelected && !widget.isDisabled;
    final iconColor = widget.isDisabled
        ? AppColors.textDisabled
        : isSelected
            ? AppColors.primary
            : _isHovered
                ? AppColors.textPrimary
                : AppColors.textSecondary;
    final textColor = widget.isDisabled
        ? AppColors.textDisabled
        : isSelected
            ? AppColors.textPrimary
            : _isHovered
                ? AppColors.textPrimary
                : AppColors.textSecondary;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: widget.isDisabled
          ? SystemMouseCursors.forbidden
          : SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: widget.isDisabled
                ? Colors.transparent
                : isSelected
                    ? AppColors.primary.withValues(alpha: 0.12)
                    : _isHovered
                        ? AppColors.surfaceVariant.withValues(alpha: 0.3)
                        : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Icon(
                    isSelected ? widget.selectedIcon : widget.icon,
                    size: 22,
                    color: iconColor,
                  ),
                  if (widget.badge != null)
                    Positioned(
                      top: -3,
                      right: -3,
                      child: widget.badge!,
                    ),
                ],
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  widget.label,
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                    color: textColor,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Mobile bottom navigation bar
class _ModernBottomNav extends StatelessWidget {
  final String location;
  final ValueChanged<String> onNavigate;
  final bool isOffline;
  final bool showBackToMydia;

  const _ModernBottomNav({
    required this.location,
    required this.onNavigate,
    this.isOffline = false,
    this.showBackToMydia = false,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: DecoratedBox(
          // Drop shadow lives on an outer box; GlassSurface clips its own
          // blurred fill so the pill now reads as true frosted glass over the
          // ambient backdrop instead of a near-opaque surface.
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.1),
                blurRadius: 16,
                spreadRadius: 2,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: GlassSurface(
            blurSigma: 10,
            fillColor: AppColors.surface.withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
              color: AppColors.border.withValues(alpha: 0.2),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  if (showBackToMydia)
                    _NavItem(
                      icon: Icons.arrow_back_rounded,
                      selectedIcon: Icons.arrow_back_rounded,
                      label: 'Mydia',
                      isSelected: false,
                      onTap: navigateToMydiaApp,
                    ),
                  _NavItem(
                    icon: Icons.home_outlined,
                    selectedIcon: Icons.home_rounded,
                    label: 'Home',
                    isSelected: _AppShellState._isHomeSection(location),
                    isDisabled: isOffline,
                    onTap: () => onNavigate('/'),
                  ),
                  _NavItem(
                    icon: Icons.movie_outlined,
                    selectedIcon: Icons.movie_rounded,
                    label: 'Movies',
                    isSelected: location.startsWith('/movies'),
                    isDisabled: isOffline,
                    onTap: () => onNavigate('/movies'),
                  ),
                  _NavItem(
                    icon: Icons.tv_outlined,
                    selectedIcon: Icons.tv_rounded,
                    label: 'Shows',
                    isSelected: location.startsWith('/shows'),
                    isDisabled: isOffline,
                    onTap: () => onNavigate('/shows'),
                  ),
                  if (isDownloadSupported)
                    _NavItem(
                      icon: Icons.download_outlined,
                      selectedIcon: Icons.download_rounded,
                      label: 'Downloads',
                      isSelected: location.startsWith('/downloads'),
                      onTap: () => onNavigate('/downloads'),
                    )
                  else
                    _NavItem(
                      icon: Icons.favorite_outline_rounded,
                      selectedIcon: Icons.favorite_rounded,
                      label: 'Favorites',
                      isSelected: location.startsWith('/favorites'),
                      isDisabled: isOffline,
                      onTap: () => onNavigate('/favorites'),
                    ),
                  _SettingsNavItem(
                    isSelected: location.startsWith('/settings'),
                    isDisabled: isOffline,
                    onTap: () => onNavigate('/settings'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Full-screen drawer for mobile navigation, mirrors the desktop sidebar.
class _MobileDrawer extends StatelessWidget {
  final String location;
  final ValueChanged<String> onNavigate;
  final bool homeExpanded;
  final bool libraryExpanded;
  final VoidCallback onToggleHome;
  final VoidCallback onToggleLibrary;
  final bool showBackToMydia;
  final bool isOffline;

  const _MobileDrawer({
    required this.location,
    required this.onNavigate,
    required this.homeExpanded,
    required this.libraryExpanded,
    required this.onToggleHome,
    required this.onToggleLibrary,
    this.showBackToMydia = false,
    this.isOffline = false,
  });

  @override
  Widget build(BuildContext context) {
    return Drawer(
      backgroundColor: AppColors.background,
      child: SafeArea(
        child: SidebarContent(
          location: location,
          onNavigate: onNavigate,
          homeExpanded: homeExpanded,
          libraryExpanded: libraryExpanded,
          onToggleHome: onToggleHome,
          onToggleLibrary: onToggleLibrary,
          isOffline: isOffline,
          backToMydiaWidget: showBackToMydia
              ? _SidebarItem(
                  icon: Icons.arrow_back_rounded,
                  selectedIcon: Icons.arrow_back_rounded,
                  label: 'Back to Mydia',
                  isSelected: false,
                  onTap: () {
                    Navigator.of(context).pop();
                    navigateToMydiaApp();
                  },
                )
              : null,
        ),
      ),
    );
  }
}

class _NavItem extends StatefulWidget {
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool isSelected;
  final bool isDisabled;
  final VoidCallback onTap;
  final Widget? badge;

  const _NavItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.isSelected,
    required this.onTap,
    this.isDisabled = false,
    this.badge,
  });

  @override
  State<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<_NavItem>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 200),
      vsync: this,
    );
    _scaleAnimation = Tween<double>(begin: 1.0, end: 0.92).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _handleTapDown(TapDownDetails details) {
    _controller.forward();
  }

  void _handleTapUp(TapUpDetails details) {
    _controller.reverse();
    widget.onTap();
  }

  void _handleTapCancel() {
    _controller.reverse();
  }

  @override
  Widget build(BuildContext context) {
    final effectiveColor = widget.isDisabled
        ? AppColors.textDisabled
        : widget.isSelected
            ? AppColors.primary
            : AppColors.textSecondary;

    return GestureDetector(
      onTapDown: _handleTapDown,
      onTapUp: _handleTapUp,
      onTapCancel: _handleTapCancel,
      child: ScaleTransition(
        scale: _scaleAnimation,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeInOut,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: widget.isSelected && !widget.isDisabled
                ? AppColors.primary.withValues(alpha: 0.12)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    child: Icon(
                      widget.isSelected && !widget.isDisabled
                          ? widget.selectedIcon
                          : widget.icon,
                      key:
                          ValueKey('${widget.isSelected}_${widget.isDisabled}'),
                      color: effectiveColor,
                      size: 24,
                    ),
                  ),
                  if (widget.badge != null)
                    Positioned(
                      top: -3,
                      right: -3,
                      child: widget.badge!,
                    ),
                ],
              ),
              const SizedBox(height: 4),
              AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 200),
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: widget.isSelected && !widget.isDisabled
                      ? FontWeight.w600
                      : FontWeight.w500,
                  color: effectiveColor,
                ),
                child: Text(widget.label),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Settings sidebar item with connection status badge.
class _SettingsSidebarItem extends ConsumerWidget {
  final bool isSelected;
  final bool isDisabled;
  final VoidCallback onTap;

  const _SettingsSidebarItem({
    required this.isSelected,
    required this.isDisabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _SidebarItem(
      icon: Icons.settings_outlined,
      selectedIcon: Icons.settings_rounded,
      label: 'Settings',
      isSelected: isSelected,
      isDisabled: isDisabled,
      onTap: onTap,
      badge: const _ConnectionStatusBadge(),
    );
  }
}

/// Settings nav item with connection status badge.
class _SettingsNavItem extends ConsumerWidget {
  final bool isSelected;
  final bool isDisabled;
  final VoidCallback onTap;

  const _SettingsNavItem({
    required this.isSelected,
    required this.isDisabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _NavItem(
      icon: Icons.settings_outlined,
      selectedIcon: Icons.settings_rounded,
      label: 'Settings',
      isSelected: isSelected,
      isDisabled: isDisabled,
      onTap: onTap,
      badge: const _ConnectionStatusBadge(),
    );
  }
}

/// Button to navigate back to the main Mydia app.
/// Shown when the player is running in embed mode.
class _BackToMydiaButton extends StatefulWidget {
  const _BackToMydiaButton();

  @override
  State<_BackToMydiaButton> createState() => _BackToMydiaButtonState();
}

class _BackToMydiaButtonState extends State<_BackToMydiaButton> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTap: navigateToMydiaApp,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: _isHovered
                ? AppColors.surfaceVariant.withValues(alpha: 0.5)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Icon(
                Icons.arrow_back_rounded,
                size: 20,
                color: _isHovered ? AppColors.primary : AppColors.textSecondary,
              ),
              const SizedBox(width: 12),
              Text(
                'Back to Mydia',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: _isHovered
                      ? AppColors.textPrimary
                      : AppColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
