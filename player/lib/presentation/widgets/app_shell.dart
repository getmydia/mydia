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
import 'mydia_logo.dart';
import 'nav/bottom_nav.dart';
import 'nav/desktop_sidebar.dart';
import 'nav/mobile_drawer.dart';
import 'nav/nav_badges.dart';
import 'nav/sidebar_row.dart';
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
                DesktopSidebar(
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
    this.backToMydiaWidget,
  });

  @override
  Widget build(BuildContext context) {
    final hasBackWidget = backToMydiaWidget != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
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
                    SidebarRow(
                      icon: Icons.fiber_new_outlined,
                      selectedIcon: Icons.fiber_new_rounded,
                      label: 'Recently Added',
                      isSelected: location.startsWith('/recently-added'),
                      isDisabled: isOffline,
                      onTap: () => onNavigate('/recently-added'),
                    ),
                    const SizedBox(height: 2),
                    SidebarRow(
                      icon: Icons.visibility_off_outlined,
                      selectedIcon: Icons.visibility_off_rounded,
                      label: 'Unwatched',
                      isSelected: location.startsWith('/unwatched'),
                      isDisabled: isOffline,
                      onTap: () => onNavigate('/unwatched'),
                    ),
                    const SizedBox(height: 2),
                    SidebarRow(
                      icon: Icons.favorite_outline_rounded,
                      selectedIcon: Icons.favorite_rounded,
                      label: 'Favorites',
                      isSelected: location.startsWith('/favorites'),
                      isDisabled: isOffline,
                      onTap: () => onNavigate('/favorites'),
                    ),
                    const SizedBox(height: 2),
                    SidebarRow(
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
                    SidebarRow(
                      icon: Icons.movie_outlined,
                      selectedIcon: Icons.movie_rounded,
                      label: 'Movies',
                      isSelected: location.startsWith('/movies'),
                      isDisabled: isOffline,
                      onTap: () => onNavigate('/movies'),
                    ),
                    const SizedBox(height: 2),
                    SidebarRow(
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
                SidebarRow(
                  icon: Icons.search_outlined,
                  selectedIcon: Icons.search_rounded,
                  label: 'Search',
                  isSelected: location.startsWith('/search'),
                  isDisabled: isOffline,
                  onTap: () => onNavigate('/search'),
                ),
                if (isDownloadSupported) ...[
                  const SizedBox(height: 8),
                  SidebarRow(
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
                SettingsSidebarRow(
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
