import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/navigation/sidebar_layout_providers.dart';
import 'package:player/core/navigation/sidebar_layout_store.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/domain/navigation/nav_destination.dart';
import 'package:player/domain/navigation/source_nav.dart';
import 'package:player/presentation/widgets/connection_status_dot.dart';
import 'package:player/presentation/widgets/nav/bottom_nav.dart';
import 'package:player/presentation/widgets/nav/sidebar_content.dart';
import 'package:player/presentation/widgets/nav/sidebar_row.dart';

import '../../screens/sources/fake_media_source.dart';

const _otherId = SourceId('acc1:owner:bb22');

Future<List<String>> _pump(
  WidgetTester tester,
  String location, {
  FocusNode? focusNode,
}) async {
  tester.view.physicalSize = const Size(1200, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final a = FakeMediaSource();
  final b = FakeMediaSource(id: _otherId);
  final navigations = <String>[];
  final container = ProviderContainer(overrides: [
    sidebarLayoutStoreProvider.overrideWithValue(InMemorySidebarLayoutStore()),
    sourcesProvider.overrideWithValue([a.source, b.source]),
    hasMydiaProvider.overrideWithValue(false),
    mediaSourceProvider(fakeSourceId).overrideWithValue(a),
    mediaSourceProvider(_otherId).overrideWithValue(b),
    allServersSourcesProvider.overrideWithValue([a, b]),
  ]);
  addTearDown(container.dispose);
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 260,
          height: 1400,
          child: SidebarContent(
            location: location,
            onNavigate: navigations.add,
            isOffline: false,
            selectedRowFocusNode: focusNode,
          ),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return navigations;
}

// Settings renders as its own row type, so look for any SidebarRow-bearing
// subtree under the keyed row.
bool _selected(WidgetTester tester, String id) => tester
    .widget<SidebarRow>(find.descendant(
        of: find.byKey(ValueKey('source-nav-$id')),
        matching: find.byType(SidebarRow)))
    .isSelected;

void main() {
  testWidgets('All servers shows the shared layout, selected row included',
      (tester) async {
    await _pump(tester, '/all/favorites');
    expect(find.byKey(const ValueKey('source-nav-favorites')), findsOneWidget);
    expect(
        find.byKey(const ValueKey('source-nav-collections')), findsOneWidget);
    expect(find.byKey(const ValueKey('source-nav-calendar')), findsNothing);
    expect(_selected(tester, 'favorites'), isTrue);
    expect(_selected(tester, 'home'), isFalse);
    expect(find.byTooltip('Edit sidebar'), findsOneWidget);
    expect(find.text('+ New filter'), findsNothing);
  });

  testWidgets('Home is selected on /all itself', (tester) async {
    await _pump(tester, '/all');
    expect(_selected(tester, 'home'), isTrue);
  });

  testWidgets('lists each server and opens its home', (tester) async {
    final navigations = await _pump(tester, '/all');
    expect(find.text('Servers'), findsOneWidget);
    final rowKey = ValueKey('all-server-row-${_otherId.value}');
    expect(find.byKey(rowKey), findsOneWidget);
    expect(find.byKey(ValueKey('all-server-row-${fakeSourceId.value}')),
        findsOneWidget);
    // Each row's dot resolves its own server from the home location.
    expect(
        find.descendant(
            of: find.byKey(rowKey), matching: find.byType(ConnectionStatusDot)),
        findsOneWidget);
    await tester.ensureVisible(find.byKey(rowKey));
    await tester.tap(find.byKey(rowKey));
    expect(navigations, ['/s/${_otherId.value}']);
  });

  testWidgets('the shell focus node sits on the selected All servers row',
      (tester) async {
    final node = FocusNode();
    addTearDown(node.dispose);
    await _pump(tester, '/all/movies', focusNode: node);
    var found = false;
    node.context!.visitAncestorElements((e) {
      final w = e.widget;
      if (w is SidebarRow && w.label == 'Movies') found = true;
      return !found;
    });
    expect(found, isTrue);
  });

  test('the bottom bar selects Home only on /all', () {
    final bar = bottomNavEntries(resolveAllServersNav(builtinDestinations),
        downloadSupported: true);
    expect(bar.map((e) => e.id),
        ['home', 'movies', 'shows', 'downloads', 'settings']);
    expect(bar.where((e) => e.matches('/all/movies')).map((e) => e.id),
        ['movies']);
    expect(bar.where((e) => e.matches('/all')).map((e) => e.id), ['home']);
  });
}
