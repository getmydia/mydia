import 'dart:math' show max;

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/sources/current_source_status.dart';
import '../../core/compatibility/compatibility_provider.dart';
import '../../core/config/web_config.dart';
import '../../core/downloads/collection_auto_sync.dart';
import '../../core/downloads/download_service.dart' show isDownloadSupported;
import '../../core/downloads/orphan_download_sweep.dart';
import '../../core/focus/region_traversal_policy.dart';
import '../../core/focus/sidebar_focus_boundary.dart';
import '../../core/layout/window_chrome_inset.dart';
import '../../core/platform/native_sidebar_state.dart';
import '../../core/platform/native_tab_bar_channel.dart';
import '../../core/platform/native_tab_bar_support.dart';
import '../../domain/navigation/source_nav.dart';
import '../../core/navigation/sidebar_layout_providers.dart';
import '../../core/router/detail_location.dart';
import '../../core/router/page_cover_observer.dart';
import '../../core/router/root_routes.dart';
import '../../core/player/input_capabilities.dart';
import '../../core/theme/depth_tokens.dart';
import '../../core/ui/reduced_motion.dart';
import '../../core/playback/playback_progress_providers.dart';
import '../../core/layout/breakpoints.dart';
import 'ambient_backdrop.dart';
import 'ambient_backdrop_provider.dart';
import 'cast_bar/dock_extents.dart';
import 'cast_bar/native_cast_accessory.dart';
import 'compatibility_banner.dart';
import 'nav/bottom_nav.dart';
import 'nav/current_source.dart';
import 'nav/floating_rail.dart';
import 'nav/mobile_drawer.dart';
import 'nav/nav_badges.dart';
import 'nav/native_sidebar_host.dart';
import 'nav/native_tab_bar.dart';
import 'offline_banner.dart';
import 'shell_rail_inset.dart';
import 'toast/toaster.dart';
import 'update_banner.dart';

/// Modern app shell with adaptive navigation.
/// Shows the floating rail at 600px and wider, the bottom bar below.
/// On iOS 26 iPhones the bottom bar is the native tab bar (`NativeTabBar`).
/// Routes a viewer in offline mode may still open: downloads, and the
/// per-source pages (`/s/`), which serve what the source has cached.
bool offlineRouteAllowed(String route) =>
    route == '/downloads' ||
    route.startsWith('/s/') ||
    route.startsWith('/sources');

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
  /// clear once the floating rail is in the picture.
  ///
  /// The rail sits to the leading edge of the content column. Its collapsed
  /// footprint (`Breakpoints.railInset` + `railCollapsedWidth`, 88) is wider
  /// than either platform's leading reserve (macOS's traffic lights, 80; a
  /// Linux button group, well under that), so it already covers whatever the
  /// window controls need there. A screen's own [WindowTitleRow] still
  /// reserves that space for the strip that actually runs across the rail
  /// *and* the content column, but the content column itself must not
  /// reserve it a second time as a left margin, or every browse header would
  /// show a dead gap the rail already accounts for. The trailing edge has no
  /// such neighbour, so it is passed through untouched.
  ///
  /// Public and `@visibleForTesting` so a test can exercise the exact
  /// arithmetic the desktop branch applies, rather than a mirror that would
  /// stay green if the subtraction were dropped.
  @visibleForTesting
  static WindowChromeInsets contentInsets(WindowChromeInsets insets) =>
      insets.copyWith(
        leading: max(
          0,
          insets.leading -
              (Breakpoints.railInset + Breakpoints.railCollapsedWidth),
        ),
      );

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

  /// The desktop branch's layers: the rail footprint reporter, the content
  /// column (full width, publishing [contentLeft] plus the safe area as
  /// `ShellRailInset` for each page to inset itself by) and the rail on top,
  /// with the two focus regions wired to [boundary].
  ///
  /// Public and `@visibleForTesting` for the reason [contentInsets] is: the
  /// shell cannot be mounted by a widget test (it needs the authenticated
  /// provider graph), so the region wiring lives here where a test can drive
  /// the exact call `build` makes. [regionsEnabled] is
  /// `InputCapabilities.directionalPrimary` in the shell; a test passes true.
  /// [railBuilder] receives the callback the rail must be given as its
  /// `onExitRequested`.
  @visibleForTesting
  static Widget railLayers({
    required bool regionsEnabled,
    required double contentLeft,
    required FocusScopeNode railScope,
    required FocusScopeNode contentScope,
    required SidebarFocusBoundary boundary,
    required Widget content,
    required Widget Function(VoidCallback onExitRequested) railBuilder,
  }) =>
      Builder(
        builder: (context) {
          // The rail sits inside the safe area (see FloatingRail), so the
          // column and the reported footprint start that much further in.
          final safeLeft = MediaQuery.paddingOf(context).left;
          final left = contentLeft + safeLeft;
          final duration =
              context.reducedMotionDuration(DepthTokens.motionMedium);
          return Stack(
            fit: StackFit.expand,
            children: [
              // Reports the rail's footprint so the cast bar clears it.
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                child: IgnorePointer(
                  child: sidebarChrome(child: SizedBox(width: left)),
                ),
              ),
              Positioned.fill(
                // The content spans the whole window, under the rail, and is
                // not padded here: go_router's shell navigator wraps its
                // pages in an Overlay that clips at its own bounds, so a
                // padded navigator would stop every page's art at the column.
                // Each page insets itself by `ShellRailInset` (see
                // `ShellPageInset`), which keeps its geometry while another
                // page opens over it.
                child: MediaQuery.removePadding(
                  context: context,
                  // The inset below already includes the safe area, so
                  // screens must not apply that gap a second time.
                  removeLeft: true,
                  child: TweenAnimationBuilder<double>(
                    tween: Tween<double>(end: left),
                    duration: duration,
                    curve: DepthTokens.curveStandard,
                    child: _AppShellState._region(
                      enabled: regionsEnabled,
                      node: contentScope,
                      onExit: (direction) =>
                          direction == TraversalDirection.left
                              ? boundary.focusSidebar()
                              : false,
                      child: content,
                    ),
                    builder: (context, inset, child) =>
                        ShellRailInset(left: inset, child: child!),
                  ),
                ),
              ),
              Positioned.fill(
                child: _AppShellState._region(
                  enabled: regionsEnabled,
                  node: railScope,
                  onExit: (direction) => direction == TraversalDirection.right
                      ? boundary.focusContent()
                      : false,
                  child: railBuilder(boundary.focusContent),
                ),
              ),
            ],
          );
        },
      );

  /// Whether the shell lays out for a sidebar. On the native iPad sidebar
  /// the native width class decides, because at compact width iPadOS shows a
  /// tab bar of every top-level tab, which only the phone payload fits.
  @visibleForTesting
  static bool showsSidebarLayout({
    required NativeTabBarMode mode,
    required bool nativeRegular,
    required bool flutterShowsRail,
  }) =>
      mode == NativeTabBarMode.sidebar ? nativeRegular : flutterShowsRail;

  /// The content column's leading inset beside the native sidebar, before
  /// `railLayers` adds the safe area back. [insets.leading] already includes
  /// it, so it is taken off here. Until native reports, the collapsed rail's
  /// inset keeps the first frame from jumping.
  @visibleForTesting
  static double nativeSidebarContentLeft({
    required NativeInsets? insets,
    required double safeLeft,
  }) {
    if (insets == null) return Breakpoints.railContentInset(pinned: false);
    final edge = insets.leading - safeLeft;
    return (edge > 0 ? edge : 0) + Breakpoints.railGap;
  }

  /// On macOS the native sidebar is its own split-view pane, so the Flutter
  /// view never sits under it. On iPad it floats over (or docks beside) the
  /// one full-screen Flutter view.
  @visibleForTesting
  static bool nativeSidebarIsPane(TargetPlatform platform) =>
      platform == TargetPlatform.macOS;

  /// [nativeSidebarContentLeft], except beside the macOS pane where content
  /// starts at 0.
  @visibleForTesting
  static double nativeSidebarContentLeftFor({
    required TargetPlatform platform,
    required NativeInsets? insets,
    required double safeLeft,
  }) =>
      nativeSidebarIsPane(platform)
          ? 0
          : nativeSidebarContentLeft(insets: insets, safeLeft: safeLeft);

  /// What the content keeps clear for the window controls beside the native
  /// sidebar. On macOS the traffic lights sit over the sidebar while it
  /// shows and over the content while it is collapsed; native reports which
  /// as `chromeLeading`. Until it does, the constant reserve stays.
  @visibleForTesting
  static WindowChromeInsets nativeSidebarContentChrome({
    required TargetPlatform platform,
    required WindowChromeInsets chrome,
    required NativeInsets? insets,
  }) {
    if (!nativeSidebarIsPane(platform)) return contentInsets(chrome);
    if (insets == null || !insets.reportsChrome) return chrome;
    final reported = insets.chromeLeading;
    // AppKit keeps the lights on the physical left, which is the trailing
    // edge under RTL (see `windowChromeInsetsFor`).
    final rtl = chrome.leading == 0 && chrome.trailing > 0;
    return rtl
        ? chrome.copyWith(trailing: reported)
        : chrome.copyWith(leading: reported);
  }

  /// Whether the native sidebar shows. The iPad sidebar floats over Flutter,
  /// so it hides under any page, dialog or sheet. The macOS one is a separate
  /// pane nothing can cover, so only a page over the shell (the immersive
  /// player) collapses it.
  @visibleForTesting
  static bool nativeSidebarVisible({
    required TargetPlatform platform,
    required bool shellCurrent,
    required bool shellPopup,
    required bool coveredByPage,
  }) =>
      nativeSidebarIsPane(platform)
          ? !coveredByPage
          : nativeBarVisible(
              shellCurrent: shellCurrent,
              drawerOpen: false,
              shellPopup: shellPopup,
            );

  /// Raises the top padding to the native chrome's top inset (the floating
  /// tab bar iPadOS shows while the sidebar is hidden), so every screen's
  /// title row clears it the way it clears the status bar.
  static Widget _clearNativeTop(
    BuildContext context,
    NativeInsets? insets,
    Widget child,
  ) {
    // No MediaQuery read until there is something to clear, so platforms
    // without a native sidebar subscribe to nothing new.
    final top = insets?.top ?? 0;
    if (top <= 0) return child;
    if (top <= MediaQuery.paddingOf(context).top) return child;
    final data = MediaQuery.of(context);
    return MediaQuery(
      data: data.copyWith(
        padding: data.padding.copyWith(top: top),
        viewPadding: data.viewPadding.copyWith(top: top),
      ),
      child: child,
    );
  }

  /// Whether the native tab bar should show: the shell's route is current on
  /// the root navigator (no page, dialog or sheet above it: not the immersive
  /// player), no popup is on the shell's own navigator ([shellPopup], from
  /// `ShellPopupObserver`: a sheet (or a dialog with `useRootNavigator:
  /// false`) shown from a content screen lands there and leaves the shell
  /// route current), and the drawer is closed. The native bar is drawn above
  /// the whole Flutter view, so it must never sit over a Flutter sheet. The
  /// mobile-layout condition is the branch this is called from.
  @visibleForTesting
  static bool nativeBarVisible({
    required bool shellCurrent,
    required bool drawerOpen,
    bool shellPopup = false,
  }) =>
      shellCurrent && !drawerOpen && !shellPopup;

  /// Whether the shell reports the native bar to `ReportedNativeBar`, which
  /// makes `CastBarLayer` stand the floating cast pill down. Unlike
  /// [nativeBarVisible] this ignores popups: only a PAGE over the shell
  /// ([coveredByPage], from `PageCoverObserver`) brings the pill back. A
  /// dialog or the native accessory's own cast sheet must not, or the pill
  /// would paint over it. A popup on the shell navigator (`shellPopup` of
  /// [nativeBarVisible]) is a popup too, and is deliberately not an input.
  @visibleForTesting
  static bool nativeBarReported({
    required bool native,
    required bool coveredByPage,
  }) =>
      native && !coveredByPage;

  /// The mobile `bottomNavigationBar`: the native iOS tab bar where it is
  /// installed, `BottomNav` in [dockChrome] everywhere else, unchanged.
  @visibleForTesting
  static Widget mobileBottomBar({
    required bool native,
    required bool drawerOpen,
    required bool shellCurrent,
    bool shellPopup = false,
    required String location,
    required List<SourceNavEntry> entries,
    List<SourceNavEntry> libraryEntries = const [],
    required bool isOffline,
    required bool showBackToMydia,
    required String? settingsBadge,
    required ValueChanged<String> onNavigate,
  }) {
    if (native) {
      return NativeTabBar(
        location: location,
        entries: entries,
        onNavigate: onNavigate,
        visible: nativeBarVisible(
          shellCurrent: shellCurrent,
          drawerOpen: drawerOpen,
          shellPopup: shellPopup,
        ),
        isOffline: isOffline,
        showBackToMydia: showBackToMydia,
        settingsBadge: settingsBadge,
      );
    }
    return dockChrome(
      drawerOpen: drawerOpen,
      child: BottomNav(
        location: location,
        onNavigate: onNavigate,
        entries: entries,
        libraryEntries: libraryEntries,
        isOffline: isOffline,
        showBackToMydia: showBackToMydia,
      ),
    );
  }

  /// Reports the rail plus its gap (`Breakpoints.railContentInset`) to
  /// `DockExtents` so the floating cast bar sits beside it instead of
  /// painting over its bottom rows.
  ///
  /// Gated on the route being current for the same reason as [dockChrome]:
  /// a route pushed over the shell (the immersive player) hides the
  /// rail, and the bar must not keep leaving a gap for it.
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

  /// The last non-detail location the shell showed. A detail page belongs to
  /// no navigation row, so the rail, drawer and bottom bar read this instead
  /// (see [shellNavLocation]). Null until the shell has shown one: a deep link
  /// straight to a detail page.
  String? _originLocation;

  @override
  void didUpdateWidget(AppShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    _rememberOrigin();
  }

  void _rememberOrigin() {
    if (!isDetailLocation(widget.location)) _originLocation = widget.location;
  }

  @override
  void initState() {
    super.initState();
    _rememberOrigin();
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
    final cover = ref.read(pageCoverObserverProvider);
    if (_coverObserver != cover) {
      _coverObserver?.removeListener(_onRouteChanged);
      _coverObserver = cover..addListener(_onRouteChanged);
    }
    final popups = ref.read(shellPopupObserverProvider);
    if (_popupObserver != popups) {
      _popupObserver?.removeListener(_onRouteChanged);
      _popupObserver = popups..addListener(_onRouteChanged);
    }
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

  PageCoverObserver? _coverObserver;
  ShellPopupObserver? _popupObserver;

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
    _coverObserver?.removeListener(_onRouteChanged);
    _popupObserver?.removeListener(_onRouteChanged);
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

  /// Whether the source the current route belongs to is unreachable.
  bool _isOfflineMode() {
    return isOffline(ref.watch(routeSourceStatusProvider(widget.location)));
  }

  /// Show a toast when a disabled nav item is tapped in offline mode
  void _showOfflineToast() {
    showToast(context, 'Connect to server to access this');
  }

  void _navigateTo(String route) {
    if (_isOfflineMode() && !offlineRouteAllowed(route)) {
      _showOfflineToast();
      return;
    }
    if (opensOverShell(route)) {
      context.push(route);
    } else {
      context.go(route);
    }
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
  static Widget _region({
    required bool enabled,
    required Widget child,
    required RegionExitCallback onExit,
    required FocusScopeNode node,
  }) {
    if (!enabled) return child;
    return FocusTraversalGroup(
      policy: RegionTraversalPolicy(onExit: onExit),
      child: FocusScope(node: node, child: child),
    );
  }

  /// The offline, compatibility and update banners, stacked.
  Widget _banners(bool isOffline) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isOffline) OfflineBanner(location: widget.location),
          const CompatibilityBanner(),
          const UpdateBanner(),
        ],
      );

  @override
  Widget build(BuildContext context) {
    // What the navigation reads: the page itself, or for a detail page the
    // page it was opened from. Banners and offline gating keep using the real
    // location, whose source is the one on screen either way.
    final location = shellNavLocation(widget.location, origin: _originLocation);
    final showBackToMydia = isEmbedMode;
    final isOffline = _isOfflineMode();

    // Keeps the offline progress flush alive for the whole app session:
    // AppShell mounts for every reachable route before the immersive player
    // (which renders outside this shell) can be reached, so watching it once
    // here is enough for the underlying provider, which is not autoDispose,
    // to keep listening for the rest of the session.
    ref.watch(sourceProgressFlushProvider);
    ref.watch(orphanDownloadSweepProvider);
    // Use MediaQuery instead of LayoutBuilder to determine layout.
    // LayoutBuilder defers building to the layout phase, which can prevent
    // proper repaint propagation on mobile when combined with GlobalKey
    // on the Scaffold (causing the "stuck navigation" bug).
    final nativeMode = NativeTabBarSupport.mode;
    final nativeSidebar = nativeMode == NativeTabBarMode.sidebar;
    final showsRail = AppShell.showsSidebarLayout(
      mode: nativeMode,
      nativeRegular: nativeSidebar && ref.watch(nativeSidebarRegularProvider),
      flutterShowsRail: Breakpoints.showsRail(context),
    );
    final route = ModalRoute.of(context);
    // Any route above the shell (page, dialog, sheet) hides the native bar.
    final shellCurrent = route?.isCurrent ?? true;
    // A dialog or sheet on the shell's own navigator hides it too. This never
    // feeds the cast pill below: a popup must not bring the pill back.
    final shellPopup = _popupObserver?.hasPopup ?? false;
    // Only a page above the shell brings the floating cast pill back.
    final coveredByPage = _coverObserver?.isCovered(route) ?? false;

    // Shell-level ambient backdrop, fed by the active browse screen. Sits behind
    // the (now transparent) in-shell Scaffolds for all browse screens (plan U5).
    final backdropSource = ref.watch(ambientBackdropControllerProvider);
    final backdrop = AmbientBackdrop(
      imageUrl: backdropSource.imageUrl,
      id: backdropSource.id,
      headers: backdropSource.headers,
      cacheKey: backdropSource.cacheKey,
    );

    if (showsRail) {
      final platform = defaultTargetPlatform;
      final pinned = ref.watch(railPinnedProvider);
      final nativeInsets =
          nativeSidebar ? ref.watch(nativeSidebarInsetsProvider) : null;
      final contentLeft = nativeSidebar
          ? AppShell.nativeSidebarContentLeftFor(
              platform: platform,
              insets: nativeInsets,
              safeLeft: MediaQuery.paddingOf(context).left,
            )
          : Breakpoints.railContentInset(pinned: pinned);
      final chrome = WindowChromeInsets.of(context);
      return Scaffold(
        backgroundColor: Colors.transparent,
        body: Stack(
          children: [
            Positioned.fill(child: backdrop),
            Positioned.fill(
              child: AppShell.railLayers(
                // UIKit owns focus in the native sidebar.
                regionsEnabled:
                    !nativeSidebar && InputCapabilities.directionalPrimary,
                contentLeft: contentLeft,
                railScope: _sidebarScopeNode,
                contentScope: _contentScopeNode,
                boundary: _focusBoundary,
                // The rail already covers the leading window-control
                // reserve, so the content column narrows what it keeps
                // clear to `AppShell.contentInsets` before its own screen
                // (via `WindowTitleRow`) reads `WindowChromeInsets.of`.
                content: AppShell._clearNativeTop(
                  context,
                  nativeInsets,
                  WindowChromeInsets.scope(
                    insets: nativeSidebar
                        ? AppShell.nativeSidebarContentChrome(
                            platform: platform,
                            chrome: chrome,
                            insets: nativeInsets,
                          )
                        : AppShell.contentInsets(chrome),
                    child: AppShell.contentGutter(
                      child: Column(
                        children: [
                          // The banners belong beside the rail, not under it.
                          AppShell.bannerArea(
                            child: ShellPageInset(child: _banners(isOffline)),
                          ),
                          Expanded(child: widget.child),
                        ],
                      ),
                    ),
                  ),
                ),
                railBuilder: (onExitRequested) => nativeSidebar
                    ? NativeSidebarHost(
                        location: location,
                        onNavigate: _navigateTo,
                        visible: AppShell.nativeSidebarVisible(
                          platform: platform,
                          shellCurrent: shellCurrent,
                          shellPopup: shellPopup,
                          coveredByPage: coveredByPage,
                        ),
                        isOffline: isOffline,
                        showBackToMydia: showBackToMydia,
                        settingsBadge: settingsTabBadge(
                            updatePending: settingsUpdatePending(ref)),
                      )
                    : FloatingRail(
                        location: location,
                        onNavigate: _navigateTo,
                        showBackToMydia: showBackToMydia,
                        isOffline: isOffline,
                        // Gated like the regions: off-tier the sidebar row falls
                        // back to the per-row node FocusHighlight creates, which
                        // is what keeps `region`'s "unchanged off-tier" claim
                        // true rather than borrowing the shell-owned node.
                        selectedRowFocusNode:
                            InputCapabilities.directionalPrimary
                                ? _sidebarFocusNode
                                : null,
                        onExitRequested: onExitRequested,
                        // Clears the macOS traffic lights; with no window chrome
                        // (phones, tablets, web) the top padding is the status
                        // bar instead, which the rail must clear too.
                        topInset: chrome.leading > 0
                            ? chrome.height
                            : chrome.isZero
                                ? MediaQuery.paddingOf(context).top
                                : 0,
                      ),
              ),
            ),
          ],
        ),
      );
    }

    final navEntries = ref.watch(sourceNavEntriesProvider(location));
    final native = NativeTabBarSupport.supported;

    return ReportedNativeBar(
      shown: AppShell.nativeBarReported(
          native: native, coveredByPage: coveredByPage),
      child: ReportedDrawer(
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
            // Navigates without popping, so the drawer stays open on the new
            // server's nav and the viewer sees the switch land.
            onSwitchSource: _navigateTo,
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
                    AppShell.bannerArea(child: _banners(isOffline)),
                    Expanded(child: widget.child),
                  ],
                ),
              ),
              if (native) const NativeCastAccessory(),
            ],
          ),
          bottomNavigationBar: AppShell.mobileBottomBar(
            native: native,
            drawerOpen: _drawerOpen,
            shellCurrent: shellCurrent,
            shellPopup: shellPopup,
            location: location,
            entries: bottomNavEntries(
              navEntries,
              downloadSupported: isDownloadSupported,
            ),
            libraryEntries: libraryNavEntries(navEntries),
            isOffline: isOffline,
            showBackToMydia: showBackToMydia,
            settingsBadge: native
                ? settingsTabBadge(updatePending: settingsUpdatePending(ref))
                : null,
            onNavigate: _navigateTo,
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
