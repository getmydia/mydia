import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/domain/navigation/source_nav.dart';
import 'package:player/l10n/l10n.dart';
import 'package:player/presentation/widgets/nav/native_sidebar.dart';
import 'package:player/presentation/widgets/nav/native_tab_bar.dart';

SourceNavEntry _entry(String id, String route, {bool anchored = false}) =>
    SourceNavEntry(
      id: id,
      label: 'Label $id',
      icon: Icons.circle_outlined,
      selectedIcon: Icons.circle,
      route: route,
      anchored: anchored,
    );

final _entries = [
  _entry('search', '/s/aa/search', anchored: true),
  _entry('home', '/s/aa'),
  _entry('movies', '/s/aa/library/movies'),
  _entry('shows', '/s/aa/library/shows'),
  _entry('library-lib9', '/s/aa/library/lib9'),
  _entry('f-123', '/s/aa/filter/f-123'),
  _entry('downloads', '/downloads', anchored: true),
  _entry('settings', '/settings', anchored: true),
];

NativeSidebar _build({
  List<SourceNavEntry>? entries,
  List<NativeSidebarServer> servers = const [],
  bool canFilter = true,
  bool isOffline = false,
  bool showBackToMydia = false,
  String? sourceHeader = 'Attic Server',
  String? settingsBadge,
  bool grouped = false,
}) =>
    nativeSidebarFor(
      l10n: lookupAppLocalizations(const Locale('en')),
      entries: entries ?? _entries,
      servers: servers,
      canFilter: canFilter,
      isOffline: isOffline,
      showBackToMydia: showBackToMydia,
      sourceHeader: sourceHeader,
      settingsBadge: settingsBadge,
      grouped: grouped,
    );

List<String> _ids(NativeSidebarSection s) => [for (final i in s.items) i.id];

void main() {
  test('sections follow the Flutter sidebar order', () {
    final sidebar = _build();
    expect([for (final s in sidebar.sections) s.id],
        ['leading', 'main', 'trailing']);
    expect(_ids(sidebar.sections[0]), [kSourceHeaderId, 'search']);
    expect(_ids(sidebar.sections[1]), [
      'home',
      'movies',
      'shows',
      'library-lib9',
      'f-123',
      kNewFilterId,
    ]);
    expect(
        _ids(sidebar.sections[2]), [kEditSidebarId, 'downloads', 'settings']);
  });

  test('grouped puts builtin pages under Library and the rest under Filters',
      () {
    final sidebar = _build(entries: [
      ..._entries.take(2),
      _entry('recently_added', '/s/aa/recently-added'),
      ..._entries.skip(2),
    ], grouped: true);
    expect([for (final s in sidebar.sections) s.id],
        ['leading', 'library', 'filters', 'trailing']);
    expect(sidebar.sections[1].title, 'Library');
    expect(
        _ids(sidebar.sections[1]), ['home', 'movies', 'shows', 'library-lib9']);
    expect(sidebar.sections[2].title, 'Filters');
    expect(
        _ids(sidebar.sections[2]), ['recently_added', 'f-123', kNewFilterId]);
  });

  test('grouped drops an empty Filters heading', () {
    final sidebar = _build(
      entries: _entries.where((e) => !e.id.startsWith('f-')).toList(),
      canFilter: false,
      grouped: true,
    );
    expect([for (final s in sidebar.sections) s.id],
        ['leading', 'library', 'trailing']);
  });

  test('the header row names the server and is an action', () {
    final header = _build().sections.first.items.first;
    expect(header.title, 'Attic Server');
    expect(header.kind, NativeSidebarItemKind.action);
  });

  test('no header row without a source header', () {
    expect(_ids(_build(sourceHeader: null).sections.first), ['search']);
  });

  test('embed mode leads with the Mydia back item', () {
    final leading = _build(showBackToMydia: true).sections.first;
    expect(leading.items.first.id, kMydiaBackTabId);
    expect(leading.items.first.enabled, isTrue);
  });

  test('All servers adds a Servers section of server rows', () {
    final sidebar = _build(
      canFilter: false,
      servers: const [(id: SourceId('acc1:owner:aa11'), name: 'Den Box')],
    );
    final servers = sidebar.sections.firstWhere((s) => s.id == 'servers');
    expect(servers.title, 'Servers');
    expect(_ids(servers), ['server-acc1:owner:aa11']);
    expect(servers.items.single.title, 'Den Box');
    expect(_ids(sidebar.sections[1]), isNot(contains(kNewFilterId)));
  });

  test('with no source only the anchors and Edit remain', () {
    final sidebar = _build(
      entries: [
        _entry('downloads', '/downloads', anchored: true),
        _entry('settings', '/settings', anchored: true),
      ],
      canFilter: false,
      sourceHeader: null,
    );
    expect([for (final s in sidebar.sections) s.id], ['trailing']);
  });

  test('offline disables everything but Downloads, the header, Edit and back',
      () {
    final sidebar = _build(isOffline: true, showBackToMydia: true);
    final enabled = [
      for (final i in sidebar.items)
        if (i.enabled) i.id,
    ];
    expect(enabled,
        [kMydiaBackTabId, kSourceHeaderId, kEditSidebarId, 'downloads']);
  });

  test('Settings is last and carries the badge', () {
    final last = _build(settingsBadge: '1').items.last;
    expect(last.id, 'settings');
    expect(last.badge, '1');
  });

  test('every item has a real symbol', () {
    final sidebar = _build(
      showBackToMydia: true,
      servers: const [(id: SourceId('x'), name: 'X')],
    );
    for (final item in sidebar.items) {
      expect(item.symbol, isNot('circle'), reason: item.id);
    }
    expect(nativeSidebarSymbol('library-lib9'), 'rectangle.stack');
    expect(nativeSidebarSymbol('server-x'), 'server.rack');
    expect(nativeSidebarSymbol('f-123'), 'line.3.horizontal.decrease.circle');
    for (final id in [
      'search',
      'home',
      'continue_watching',
      'movies',
      'shows',
      'calendar',
      'recently_added',
      'unwatched',
      'favorites',
      'collections',
      'downloads',
      'settings',
    ]) {
      expect(nativeTabSymbol(id), isNot('circle'), reason: id);
    }
  });

  test('selection is the longest matching route', () {
    expect(selectedNativeSidebarId(_entries, '/s/aa'), 'home');
    expect(
        selectedNativeSidebarId(_entries, '/s/aa/library/movies/x'), 'movies');
    expect(selectedNativeSidebarId(_entries, '/sources/manage'), isNull);
  });

  test('toMap is what the native side reads', () {
    final map = _build(sourceHeader: null, canFilter: false).toMap();
    final sections = map['sections']! as List;
    final first = sections.first as Map;
    expect(first['id'], 'leading');
    expect((first['items'] as List).single, {
      'id': 'search',
      'title': 'Label search',
      'symbol': 'magnifyingglass',
      'badge': null,
      'enabled': true,
      'kind': 'destination',
      'inTabBar': true,
    });
  });

  test('the floating tab bar gets Search and the iPhone bar\'s first three',
      () {
    final inBar = [
      for (final item in _build(showBackToMydia: true).items)
        if (item.inTabBar) item.id,
    ];
    expect(inBar, ['search', 'home', 'movies', 'shows']);
  });

  test('equal inputs give equal sidebars', () {
    expect(_build(), _build());
    expect(_build(), isNot(_build(isOffline: true)));
  });
}
