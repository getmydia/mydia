import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/web_config.dart';
import '../../../core/platform/native_tab_bar_channel.dart';
import '../../../domain/navigation/source_nav.dart';
import '../toast/toast_obstruction.dart';

/// Id of the embed-mode back item, which is not a source entry.
const String kMydiaBackTabId = 'mydia-back';

/// SF Symbols for each bar entry. A new entry is one line here.
const Map<String, String> _tabSymbols = {
  kMydiaBackTabId: 'chevron.backward',
  'home': 'house.fill',
  'movies': 'film.fill',
  'shows': 'tv.fill',
  'downloads': 'arrow.down.circle.fill',
  'favorites': 'heart.fill',
  'settings': 'gearshape.fill',
};

/// The SF Symbol for the entry [id]; `circle` for one this map lacks.
String nativeTabSymbol(String id) => _tabSymbols[id] ?? 'circle';

/// The native Settings badge. Only a waiting update earns one: the Flutter
/// badge's connection-tone dot is always lit, which on a native bar would be
/// a permanent badge that means nothing.
String? settingsTabBadge({required bool updatePending}) =>
    updatePending ? '1' : null;

/// The native tabs for the bar [entries] (see `bottomNavEntries`). Offline,
/// everything but Downloads is disabled, as on `BottomNav`; the back item
/// stays usable.
List<NativeTab> nativeTabsFor(
  List<SourceNavEntry> entries, {
  required bool isOffline,
  required bool showBackToMydia,
  String? settingsBadge,
}) =>
    [
      if (showBackToMydia)
        NativeTab(
          id: kMydiaBackTabId,
          title: 'Mydia',
          symbol: nativeTabSymbol(kMydiaBackTabId),
        ),
      for (final entry in entries)
        NativeTab(
          id: entry.id,
          title: entry.shortLabel ?? entry.label,
          symbol: nativeTabSymbol(entry.id),
          badge: entry.id == 'settings' ? settingsBadge : null,
          enabled: !isOffline || entry.id == 'downloads',
        ),
    ];

/// The entry [location] falls under, or null where none does. A native tab
/// bar always has a selection, so null means "leave it where it is".
String? selectedNativeTabId(List<SourceNavEntry> entries, String location) =>
    entries.where((e) => e.matches(location)).firstOrNull?.id;

/// The iOS 26 native tab bar, driven from the shell.
///
/// Sits in `Scaffold.bottomNavigationBar` where `BottomNav` would, and draws
/// nothing but a pointer-transparent box as tall as the native bar. With
/// `extendBody`, the Scaffold publishes that height as the body's
/// `padding.bottom`, which is what `DockInsets` reads, so every screen clears
/// the native bar exactly as it did for the Flutter dock. The box is also a
/// bottom toast obstruction, so toasts sit above the bar.
///
/// The route decides the selection: a tap arrives as [onNavigate] (the
/// shell's offline rule still applies), and the resulting [location] comes
/// back here and is sent as `select`.
class NativeTabBar extends ConsumerStatefulWidget {
  const NativeTabBar({
    super.key,
    required this.location,
    required this.entries,
    required this.onNavigate,
    required this.visible,
    this.isOffline = false,
    this.showBackToMydia = false,
    this.settingsBadge,
    this.onBackToMydia = navigateToMydiaApp,
  });

  /// The Flutter dock's measured height without a home indicator, used until
  /// native reports its own, so the first frame does not jump.
  static const double fallbackBarHeight = 83;

  final String location;
  final List<SourceNavEntry> entries;
  final ValueChanged<String> onNavigate;
  final bool visible;
  final bool isOffline;
  final bool showBackToMydia;
  final String? settingsBadge;
  final VoidCallback onBackToMydia;

  @override
  ConsumerState<NativeTabBar> createState() => _NativeTabBarState();
}

class _NativeTabBarState extends ConsumerState<NativeTabBar> {
  // Read once: `dispose` must still reach the channel to hide the bar.
  late final NativeTabBarChannel _channel =
      ref.read(nativeTabBarChannelProvider);
  StreamSubscription<NativeTabBarEvent>? _events;
  double? _inset;

  @override
  void initState() {
    super.initState();
    _events = _channel.events.listen(_onEvent);
  }

  @override
  void dispose() {
    unawaited(_events?.cancel());
    // Leaving the mobile layout (rotation to a desktop width, sign-out)
    // takes the bar with it.
    unawaited(_channel.setVisible(false));
    super.dispose();
  }

  void _onEvent(NativeTabBarEvent event) {
    switch (event) {
      case NativeTabSelected(:final id):
        _onTabSelected(id);
      case NativeInsetsChanged(:final bottom):
        // 0 means the bar is hidden: the drawer is open or a route covers the
        // shell. Keeping the last real height holds every screen's DockInsets
        // steady behind the drawer, as dockChrome's fade does for BottomNav.
        if (bottom > 0 && bottom != _inset && mounted) {
          setState(() => _inset = bottom);
        }
      case NativeAccessoryTapped() || NativeAccessoryPlayPause():
        break;
    }
  }

  void _onTabSelected(String id) {
    if (id == kMydiaBackTabId) {
      widget.onBackToMydia();
      return;
    }
    final entry = widget.entries.where((e) => e.id == id).firstOrNull;
    if (entry == null) {
      debugPrint('[NativeTabBar] ignored unknown tab $id');
      return;
    }
    widget.onNavigate(entry.route);
  }

  void _sync() {
    unawaited(_channel.setTabs(nativeTabsFor(
      widget.entries,
      isOffline: widget.isOffline,
      showBackToMydia: widget.showBackToMydia,
      settingsBadge: widget.settingsBadge,
    )));
    final selected = selectedNativeTabId(widget.entries, widget.location);
    if (selected != null) unawaited(_channel.select(selected));
    unawaited(_channel.setVisible(widget.visible));
  }

  @override
  Widget build(BuildContext context) {
    // After the frame: a channel call is a side effect, and the channel drops
    // repeats, so syncing on every build costs nothing.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _sync();
    });
    final height = _inset ??
        NativeTabBar.fallbackBarHeight +
            MediaQuery.viewPaddingOf(context).bottom;
    return IgnorePointer(
      child: ToastObstruction(
        edge: ToastEdge.bottom,
        active: widget.visible,
        child: SizedBox(
          key: const Key('native-tab-bar-inset'),
          width: double.infinity,
          height: height,
        ),
      ),
    );
  }
}
