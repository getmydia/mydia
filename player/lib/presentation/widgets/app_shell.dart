import 'dart:math' show max;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/auth/auth_status.dart';
import '../../core/compatibility/compatibility_provider.dart';
import '../../core/config/web_config.dart';
import '../../core/downloads/collection_auto_sync.dart';
import '../../core/downloads/download_service.dart' show isDownloadSupported;
import '../../core/focus/region_traversal_policy.dart';
import '../../core/focus/sidebar_focus_boundary.dart';
import '../../core/graphql/graphql_provider.dart';
import '../../core/layout/window_chrome_inset.dart';
import '../../core/navigation/sidebar_layout_providers.dart';
import '../../core/player/input_capabilities.dart';
import '../../core/playback/playback_progress_providers.dart';
import '../../core/layout/breakpoints.dart';
import 'ambient_backdrop.dart';
import 'ambient_backdrop_provider.dart';
import 'cast_bar/dock_extents.dart';
import 'compatibility_banner.dart';
import 'nav/bottom_nav.dart';
import 'nav/desktop_sidebar.dart';
import 'nav/mobile_drawer.dart';
import 'offline_banner.dart';
import 'toast/toaster.dart';
import 'update_banner.dart';

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

  /// Narrows [insets] to what the desktop content column still has to keep
  /// clear once [DesktopSidebar] is in the picture.
  ///
  /// The sidebar sits to the leading edge of the content column and is wider
  /// (`Breakpoints.sidebarWidth`, 260) than either platform's leading
  /// reserve (macOS's traffic lights, 80; a Linux button group, well under
  /// 260), so it already covers whatever the window controls need there. A
  /// screen's own [WindowTitleRow] still reserves that space for the strip
  /// that actually runs across the sidebar *and* the content column, but the
  /// content column itself must not reserve it a second time as a left
  /// margin, or every browse header would show a dead gap the sidebar
  /// already accounts for. The trailing edge has no such neighbour, so it is
  /// passed through untouched.
  ///
  /// Public and `@visibleForTesting` so a test can exercise the exact
  /// arithmetic the desktop branch applies, rather than a mirror that would
  /// stay green if the subtraction were dropped.
  @visibleForTesting
  static WindowChromeInsets contentInsets(WindowChromeInsets insets) => insets
      .copyWith(leading: max(0, insets.leading - Breakpoints.sidebarWidth));

  /// The content column's top edge is the window's: each screen's
  /// [WindowTitleRow] draws into the title-bar band. Only [bannerArea]
  /// clears it.
  @visibleForTesting
  static Widget contentGutter({required Widget child}) => child;

  /// The shell's banners sit above the screen, so they have to clear the
  /// band themselves, but only while one is showing: an idle banner area
  /// must not push the screen's title row down out of the band.
  ///
  /// `_PadTopWhenNonEmpty` reads the ambient `MediaQuery.padding.top` (via
  /// its own element, still above this `Builder`) to know how far to shift
  /// [child] down, but [child] itself gets that same top padding removed
  /// first. Without the removal, a banner that wraps its own content in
  /// `SafeArea(bottom: false)` -- `CompatibilityBanner` and `UpdateBanner`
  /// both do -- would apply the band inset a second time on top of the shift
  /// this widget already gives it, doubling the empty space above the
  /// banner's text.
  @visibleForTesting
  static Widget bannerArea({required Widget child}) => Builder(
        builder: (context) => _PadTopWhenNonEmpty(
          child: MediaQuery.removePadding(
            context: context,
            removeTop: true,
            child: child,
          ),
        ),
      );

  /// Wraps the bottom dock so it disappears while the nav drawer is open.
  ///
  /// In `Scaffold.build`, the drawer slot is added to the child list before
  /// `bottomNavigationBar`, and the layout paints in that order. So a floating
  /// dock would otherwise sit on top of the drawer AND its scrim, and keep
  /// intercepting taps: tapping where "Home" sits navigates while the drawer
  /// is open.
  ///
  /// `app_shell_drawer_dock_test.dart` pins this behaviour, so a Flutter
  /// upgrade that reorders those slots surfaces there rather than here.
  ///
  /// [child] stays MOUNTED rather than being swapped for `null`. Removing the
  /// bar would drop `MediaQuery.padding.bottom` to zero, which is the exact
  /// value every screen's `DockInsets.bottomOf` reads, so all content would
  /// reflow behind the open drawer and reflow back on close. Fading in place
  /// holds the measured height stable.
  ///
  /// 200ms sits just inside Flutter's drawer settle duration (246ms), so the
  /// dock is gone before the drawer finishes arriving.
  ///
  /// Also reports the dock's height to `DockExtents` so the floating cast bar
  /// can sit above it instead of painting over it.
  ///
  /// Public and `@visibleForTesting` for the reason [contentInsets] and
  /// [bannerArea] are: a test can exercise the exact widget the shell
  /// builds, instead of a mirror that silently drifts from the real call site
  /// and would stay green if this wrapper were deleted.
  @visibleForTesting
  static Widget dockChrome({
    required bool drawerOpen,
    required Widget child,
  }) =>
      Builder(
        builder: (context) => ReportedExtent(
          onExtent: DockExtents.reporterOf(context)?.onDock,
          // A route pushed over the shell (the immersive player) keeps the
          // shell mounted underneath; the bar must not keep floating at dock
          // height over a screen that has no dock.
          active: ModalRoute.of(context)?.isCurrent ?? true,
          child: IgnorePointer(
            ignoring: drawerOpen,
            child: AnimatedOpacity(
              opacity: drawerOpen ? 0 : 1,
              duration: const Duration(milliseconds: 200),
              child: child,
            ),
          ),
        ),
      );

  /// Reports the desktop sidebar's width to `DockExtents` so the floating
  /// cast bar sits beside it instead of painting over its bottom rows.
  ///
  /// Gated on the route being current for the same reason as [dockChrome]:
  /// a route pushed over the shell (the immersive player) hides the
  /// sidebar, and the bar must not keep leaving a gap for it.
  @visibleForTesting
  static Widget sidebarChrome({required Widget child}) => Builder(
        builder: (context) => ReportedExtent(
          onExtent: DockExtents.reporterOf(context)?.onSidebar,
          axis: Axis.horizontal,
          active: ModalRoute.of(context)?.isCurrent ?? true,
          child: child,
        ),
      );

  /// Reacts to the mobile drawer opening or closing.
  ///
  /// Edit mode is ephemeral, and `Scaffold.drawer` keeps its child mounted
  /// while closed, so without this the drawer reopens in whatever mode it was
  /// left in. Order changes persist on every drop, so exiting loses nothing.
  ///
  /// Public and `@visibleForTesting` for the reason [contentInsets] and
  /// [bannerArea] are: a test can exercise the exact call the shell makes,
  /// rather than a mirror that would stay green if the wiring below were
  /// deleted.
  @visibleForTesting
  static void onDrawerVisibilityChanged({
    required bool isOpen,
    required WidgetRef ref,
  }) {
    if (isOpen) return;
    ref.read(sidebarEditModeProvider.notifier).exit();
  }

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell>
    with WidgetsBindingObserver {
  GoRouter? _router;
  CollectionAutoSync? _collectionAutoSync;

  /// Whether the nav drawer is open. Drives [AppShell.dockChrome], and the
  /// cast bar's fade through [ReportedDrawer].
  bool _drawerOpen = false;

  /// Node for the sidebar's selected row. Also the boundary's target, so one
  /// node serves both the row that takes focus and the shell that asks for it.
  ///
  /// The boundary that uses it — and the memory of which card focus came from,
  /// so the move is a round trip rather than a one-way jump — lives in
  /// [SidebarFocusBoundary], where a test can drive it. The shell itself cannot
  /// be mounted by a widget test: it needs the authenticated provider graph.
  final FocusNode _sidebarFocusNode = FocusNode(debugLabel: 'sidebar-selected');

  /// The two regions' scopes.
  ///
  /// Owned here rather than left to `FocusScope`'s implicit node, because
  /// [SidebarFocusBoundary] falls back to the *first focusable inside the
  /// content region* when the node it remembered has been disposed by a route
  /// change, and finding that needs the region's own scope to enumerate.
  ///
  /// Both keep the default `directionalTraversalEdgeBehavior` of
  /// [TraversalEdgeBehavior.stop], which is load-bearing: under `closedLoop`
  /// or `parentScope` the traversal mixin resolves the region edge inside
  /// `inDirection`, before [RegionTraversalPolicy.onExit] is ever consulted —
  /// so the boundary would silently stop calling back and the sidebar would
  /// become unreachable again, with no test failing. Do not reconfigure these
  /// nodes.
  final FocusScopeNode _sidebarScopeNode =
      FocusScopeNode(debugLabel: 'sidebar-region');
  final FocusScopeNode _contentScopeNode =
      FocusScopeNode(debugLabel: 'content-region');

  late final SidebarFocusBoundary _focusBoundary = SidebarFocusBoundary(
    sidebarNode: _sidebarFocusNode,
    contentScope: _contentScopeNode,
  );

  @override
  void initState() {
    super.initState();
    _collectionAutoSync = ref.read(collectionAutoSyncProvider)(ref);
    _collectionAutoSync!.install(
      enabled: isDownloadSupported,
      onQueued: _showAutoSyncToast,
    );
    WidgetsBinding.instance.addObserver(this);
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
  void didChangeAppLifecycleState(AppLifecycleState lifecycleState) {
    // An operator may have upgraded the server while we were backgrounded, so
    // re-ask on the way back in.
    //
    // The catchError is load-bearing, not defensive noise. refresh() awaits the
    // rebuilt future, and if that rebuild lands on AsyncValue.error (the
    // PackageInfo lookup or the Hive box open failing), the await rethrows.
    // This call site is fire and forget, so an unguarded rejection would
    // surface as an unhandled async error from a lifecycle callback. Swallowing
    // it is correct here: a failed refresh leaves the provider in its error
    // state, which the banner already renders as nothing.
    if (lifecycleState == AppLifecycleState.resumed) {
      ref.read(compatibilityProvider.notifier).refresh().catchError(
          (Object e) => debugPrint('[AppShell] refresh failed: $e'));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _router?.routerDelegate.removeListener(_onRouteChanged);
    _collectionAutoSync?.dispose();
    _sidebarFocusNode.dispose();
    _sidebarScopeNode.dispose();
    _contentScopeNode.dispose();
    super.dispose();
  }

  void _showAutoSyncToast(int totalQueued) {
    if (totalQueued > 0 && mounted) {
      showToast(
        context,
        'Auto-sync: queued $totalQueued new item${totalQueued != 1 ? 's' : ''} for download',
        icon: Icons.sync_rounded,
      );
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

  /// Show a toast when a disabled nav item is tapped in offline mode
  void _showOfflineToast() {
    showToast(context, 'Connect to server to access this');
  }

  void _navigateTo(String route) {
    if (_isOfflineMode() && route != '/downloads') {
      _showOfflineToast();
      return;
    }
    context.go(route);
  }

  /// Wraps [child] in a focus region, or returns it untouched off the
  /// directional tier.
  ///
  /// The boundary is a remote affordance: a D-pad viewer has no pointer and no
  /// Tab key, so the only way into the sidebar has to be an arrow key, and that
  /// needs a region that fails predictably at its edge. A desktop or web viewer
  /// has both a pointer and Tab, and their arrow-key behaviour today is the
  /// plain scoped geometric walk; gating here is what keeps this change from
  /// altering it. Returning `child` unwrapped rather than installing an inert
  /// region also means the non-directional tree is byte-for-byte what it was.
  ///
  /// The scope is given an explicit [FocusScopeNode] owned by this state
  /// (rather than left to `FocusScope`'s implicit one) so the region can be
  /// enumerated: [SidebarFocusBoundary] falls back to the first focusable in
  /// the content region when the node it remembered has been disposed by a
  /// route change, and [_contentScopeNode] is how it finds one. That node
  /// keeps the default `directionalTraversalEdgeBehavior` of
  /// [TraversalEdgeBehavior.stop], and that is load-bearing. Under `closedLoop`
  /// or `parentScope` the traversal mixin resolves the region edge itself,
  /// inside `inDirection`, before [RegionTraversalPolicy.onExit] is ever
  /// consulted — so the boundary would silently stop calling back and the
  /// sidebar would become unreachable again, with no test failing. Do not
  /// reconfigure these nodes.
  Widget _region({
    required Widget child,
    required RegionExitCallback onExit,
    required FocusScopeNode node,
  }) {
    if (!InputCapabilities.directionalPrimary) return child;
    return FocusTraversalGroup(
      policy: RegionTraversalPolicy(onExit: onExit),
      child: FocusScope(node: node, child: child),
    );
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
                _region(
                  node: _sidebarScopeNode,
                  onExit: (direction) => direction == TraversalDirection.right
                      ? _focusBoundary.focusContent()
                      : false,
                  child: AppShell.sidebarChrome(
                    child: DesktopSidebar(
                      location: location,
                      onNavigate: _navigateTo,
                      showBackToMydia: showBackToMydia,
                      isOffline: isOffline,
                      // Gated like the region above it: off-tier the sidebar row
                      // falls back to the per-row node FocusHighlight creates,
                      // which is what keeps `_region`'s "unchanged off-tier"
                      // claim true rather than borrowing the shell-owned node.
                      selectedRowFocusNode: InputCapabilities.directionalPrimary
                          ? _sidebarFocusNode
                          : null,
                    ),
                  ),
                ),
                Expanded(
                  child: _region(
                    node: _contentScopeNode,
                    onExit: (direction) => direction == TraversalDirection.left
                        ? _focusBoundary.focusSidebar()
                        : false,
                    // The sidebar already covers the leading window-control
                    // reserve, so the content column narrows what it keeps
                    // clear to `AppShell.contentInsets` before its own screen
                    // (via `WindowTitleRow`) reads `WindowChromeInsets.of`.
                    child: WindowChromeInsets.scope(
                      insets: AppShell.contentInsets(
                          WindowChromeInsets.of(context)),
                      child: AppShell.contentGutter(
                        child: Column(
                          children: [
                            AppShell.bannerArea(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (isOffline) const OfflineBanner(),
                                  const CompatibilityBanner(),
                                  const UpdateBanner(),
                                ],
                              ),
                            ),
                            Expanded(child: widget.child),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    }

    return ReportedDrawer(
      open: _drawerOpen,
      child: Scaffold(
        key: AppShell.scaffoldKey,
        backgroundColor: Colors.transparent,
        extendBody: true,
        onDrawerChanged: (isOpen) {
          if (!mounted) return;
          setState(() => _drawerOpen = isOpen);
          AppShell.onDrawerVisibilityChanged(isOpen: isOpen, ref: ref);
        },
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
            // Insets pass through unchanged here: a narrow mobile/macOS window
            // has no sidebar to cover the window-control reserve, so the row
            // still needs the full ambient value.
            AppShell.contentGutter(
              child: Column(
                children: [
                  AppShell.bannerArea(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (isOffline) const OfflineBanner(),
                        const CompatibilityBanner(),
                        const UpdateBanner(),
                      ],
                    ),
                  ),
                  Expanded(child: widget.child),
                ],
              ),
            ),
          ],
        ),
        bottomNavigationBar: AppShell.dockChrome(
          drawerOpen: _drawerOpen,
          child: BottomNav(
            location: location,
            onNavigate: _navigateTo,
            isOffline: isOffline,
            showBackToMydia: showBackToMydia,
          ),
        ),
      ),
    );
  }
}

/// Pads [child] by the ambient `MediaQuery.padding.top` (the title-bar band
/// plus any status bar), but only while [child] actually renders something.
///
/// [AppShell.bannerArea] wraps the offline/compatibility/update banner
/// trio, which is usually empty (`SizedBox.shrink()` all the way down). A
/// plain `Padding` would reserve the top inset unconditionally, leaving a
/// dead gap above the content column even with no banner in it. This area
/// sits above a screen's own [WindowTitleRow], so that gap would shove the
/// row itself down out of the band it is supposed to draw into. Only padding
/// when the child has a nonzero height keeps the idle case truly zero-height,
/// while a real banner still clears the band.
class _PadTopWhenNonEmpty extends SingleChildRenderObjectWidget {
  const _PadTopWhenNonEmpty({required Widget child}) : super(child: child);

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderPadTopWhenNonEmpty(top: MediaQuery.paddingOf(context).top);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderPadTopWhenNonEmpty renderObject,
  ) {
    renderObject.top = MediaQuery.paddingOf(context).top;
  }
}

class _RenderPadTopWhenNonEmpty extends RenderShiftedBox {
  _RenderPadTopWhenNonEmpty({required double top, RenderBox? child})
      : _top = top,
        super(child);

  double _top;

  set top(double value) {
    if (_top == value) return;
    _top = value;
    markNeedsLayout();
  }

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }

    child.layout(constraints.loosen(), parentUsesSize: true);
    if (child.size.height == 0) {
      // Nothing to clear the band for: stay zero-height rather than
      // reserving `_top` of dead space above an idle banner area.
      size = Size(constraints.maxWidth, 0);
      return;
    }

    (child.parentData as BoxParentData).offset = Offset(0, _top);
    size = Size(constraints.maxWidth, child.size.height + _top);
  }
}
