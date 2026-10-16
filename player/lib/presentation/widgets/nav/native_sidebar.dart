/// The iPad sidebar's rows, as Dart sends them over `setSidebar`.
///
/// Built from the same `sourceNavEntriesProvider(location)` list
/// `SidebarContent` renders, in the same order, so the native sidebar can
/// never show a different list from the Flutter one. Native only draws it.
library;

import 'package:flutter/foundation.dart';

import '../../../core/sources/source.dart';
import '../../../domain/navigation/source_nav.dart';
import 'bottom_nav.dart';
import 'native_tab_bar.dart';

enum NativeSidebarItemKind { destination, action }

// Ids of the sidebar's action rows: the current server's row (a tap opens the
// source picker), New filter, and Edit sidebar.
const String kSourceHeaderId = 'action:source-header';
const String kNewFilterId = 'action:new-filter';
const String kEditSidebarId = 'action:edit-sidebar';

/// One row per server under All servers.
String serverItemId(SourceId id) => 'server-${id.value}';

typedef NativeSidebarServer = ({SourceId id, String name});

@immutable
class NativeSidebarItem {
  const NativeSidebarItem({
    required this.id,
    required this.title,
    required this.symbol,
    this.badge,
    this.enabled = true,
    this.kind = NativeSidebarItemKind.destination,
    this.inTabBar = false,
  });

  final String id;
  final String title;

  /// An SF Symbol name.
  final String symbol;
  final String? badge;
  final bool enabled;
  final NativeSidebarItemKind kind;

  /// Also shown in the floating tab bar iPadOS draws while the sidebar is
  /// hidden. Every other row is sidebar-only.
  final bool inTabBar;

  Map<String, Object?> toMap() => {
        'id': id,
        'title': title,
        'symbol': symbol,
        'badge': badge,
        'enabled': enabled,
        'kind': kind.name,
        'inTabBar': inTabBar,
      };

  @override
  bool operator ==(Object other) =>
      other is NativeSidebarItem &&
      other.id == id &&
      other.title == title &&
      other.symbol == symbol &&
      other.badge == badge &&
      other.enabled == enabled &&
      other.kind == kind &&
      other.inTabBar == inTabBar;

  @override
  int get hashCode =>
      Object.hash(id, title, symbol, badge, enabled, kind, inTabBar);
}

@immutable
class NativeSidebarSection {
  const NativeSidebarSection({
    required this.id,
    this.title,
    required this.items,
  });

  final String id;

  /// The section header. A titled section is a collapsible group below the
  /// sidebar's rows; an untitled one adds plain rows in its place.
  final String? title;
  final List<NativeSidebarItem> items;

  Map<String, Object?> toMap() => {
        'id': id,
        'title': title,
        'items': [for (final item in items) item.toMap()],
      };

  @override
  bool operator ==(Object other) =>
      other is NativeSidebarSection &&
      other.id == id &&
      other.title == title &&
      listEquals(other.items, items);

  @override
  int get hashCode => Object.hash(id, title, Object.hashAll(items));
}

@immutable
class NativeSidebar {
  const NativeSidebar(this.sections);

  final List<NativeSidebarSection> sections;

  Iterable<NativeSidebarItem> get items =>
      sections.expand((section) => section.items);

  Map<String, Object?> toMap() => {
        'sections': [for (final section in sections) section.toMap()],
      };

  @override
  bool operator ==(Object other) =>
      other is NativeSidebar && listEquals(other.sections, sections);

  @override
  int get hashCode => Object.hashAll(sections);
}

/// The SF Symbol for a sidebar row. Builtins come from the bar's map; the
/// rest are named by kind, so a viewer's own library or filter never shows
/// a blank `circle`.
String nativeSidebarSymbol(String id) {
  if (id.startsWith('library-')) return 'rectangle.stack';
  if (id.startsWith('server-')) return 'server.rack';
  final builtin = nativeTabSymbol(id);
  if (builtin != 'circle') return builtin;
  // Every other id in a resolved layout is a saved filter's.
  return 'line.3.horizontal.decrease.circle';
}

/// The sidebar for one shell location. Mirrors `SidebarContent`: Search
/// leads, the source's rows scroll in the middle with New filter after them,
/// All servers lists its servers, and the app's own rows close the list with
/// Settings last.
NativeSidebar nativeSidebarFor({
  required List<SourceNavEntry> entries,
  required List<NativeSidebarServer> servers,
  required bool canFilter,
  required bool isOffline,
  required bool showBackToMydia,
  required String? sourceHeader,
  String? settingsBadge,
}) {
  // The floating bar leads with the iPhone bar's first three rows. Past
  // about four tabs iPadOS pages it, so the rest stay a toggle away.
  final barIds = {
    for (final entry in bottomNavEntries(
      entries,
      downloadSupported: entries.any((e) => e.id == 'downloads'),
    ).take(3))
      entry.id,
  };

  NativeSidebarItem destination(SourceNavEntry entry) => NativeSidebarItem(
        id: entry.id,
        title: entry.label,
        symbol: nativeSidebarSymbol(entry.id),
        badge: entry.id == 'settings' ? settingsBadge : null,
        // The Flutter rows' offline rule (`SidebarContent._buildRow`).
        enabled: !isOffline || entry.id == 'downloads',
        inTabBar: entry.id == 'search' || barIds.contains(entry.id),
      );

  final sections = [
    NativeSidebarSection(id: 'leading', items: [
      if (showBackToMydia)
        NativeSidebarItem(
          id: kMydiaBackTabId,
          title: 'Mydia',
          symbol: nativeSidebarSymbol(kMydiaBackTabId),
          kind: NativeSidebarItemKind.action,
        ),
      if (sourceHeader != null)
        NativeSidebarItem(
          id: kSourceHeaderId,
          title: sourceHeader,
          symbol: 'server.rack',
          kind: NativeSidebarItemKind.action,
        ),
      for (final entry in entries)
        if (entry.anchored && entry.id == 'search') destination(entry),
    ]),
    NativeSidebarSection(id: 'main', items: [
      for (final entry in entries)
        if (!entry.anchored) destination(entry),
      if (canFilter)
        NativeSidebarItem(
          id: kNewFilterId,
          title: 'New filter',
          symbol: 'plus',
          enabled: !isOffline,
          kind: NativeSidebarItemKind.action,
        ),
    ]),
    NativeSidebarSection(id: 'servers', title: 'Servers', items: [
      for (final server in servers)
        NativeSidebarItem(
          id: serverItemId(server.id),
          title: server.name,
          symbol: 'server.rack',
          enabled: !isOffline,
        ),
    ]),
    NativeSidebarSection(id: 'trailing', items: [
      const NativeSidebarItem(
        id: kEditSidebarId,
        title: 'Edit sidebar',
        symbol: 'slider.horizontal.3',
        kind: NativeSidebarItemKind.action,
      ),
      for (final entry in entries)
        if (entry.anchored && entry.id != 'search') destination(entry),
    ]),
  ];
  return NativeSidebar([
    for (final section in sections)
      if (section.items.isNotEmpty) section,
  ]);
}

/// The row [location] selects: the longest matching route, as
/// `SidebarContent.selectedFor` picks. Null means no row matches, and the
/// host clears the native selection.
String? selectedNativeSidebarId(List<SourceNavEntry> entries, String location) {
  SourceNavEntry? best;
  for (final entry in entries) {
    if (!entry.matches(location)) continue;
    if (best == null || entry.route.length > best.route.length) best = entry;
  }
  return best?.id;
}
