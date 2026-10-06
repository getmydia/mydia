// The sidebar resolves the viewer's layout against the source on screen: a
// source's own libraries and only the destinations it can serve. Edit mode
// arranges the layout itself, so it stays available at a source's location
// and is hidden only for All servers.

import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/connection/connection_provider.dart';
import 'package:player/core/navigation/sidebar_layout_providers.dart';
import 'package:player/core/navigation/sidebar_layout_store.dart';
import 'package:player/core/sources/media_source.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/presentation/widgets/nav/sidebar_content.dart';
import 'package:player/presentation/widgets/nav/sidebar_edit_bar.dart';
import 'package:player/presentation/widgets/nav/sidebar_row.dart';

import '../../screens/sources/fake_media_source.dart';

class _NotSearchable extends FakeMediaSource {
  @override
  Set<SourceCapability> get capabilities => const {};

  @override
  T? as<T extends Object>() => null;
}

class _StubConnectionNotifier extends ConnectionNotifier {
  @override
  ConnectionState build() => ConnectionState.direct();
}

Future<List<String>> _pump(
  WidgetTester tester,
  String location, {
  bool editing = true,
  bool hasMydia = true,
  FakeMediaSource? source,
  FocusNode? focusNode,
}) async {
  tester.view.physicalSize = const Size(1200, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final navigations = <String>[];
  final container = ProviderContainer(overrides: [
    connectionProvider.overrideWith(_StubConnectionNotifier.new),
    sidebarLayoutStoreProvider.overrideWithValue(InMemorySidebarLayoutStore()),
    thirdPartySourcesProvider.overrideWithValue(const [fakeSource]),
    hasMydiaProvider.overrideWithValue(hasMydia),
    mediaSourceProvider(fakeSourceId)
        .overrideWithValue(source ?? FakeMediaSource()),
  ]);
  addTearDown(container.dispose);
  if (editing) container.read(sidebarEditModeProvider.notifier).toggle();
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

void main() {
  const root = '/s/acc1:owner:aa11';

  testWidgets('a source location keeps the edit pencil and bar',
      (tester) async {
    await _pump(tester, root);
    expect(find.byTooltip('Edit sidebar'), findsOneWidget);
    expect(find.byType(SidebarEditBar), findsOneWidget);
  });

  testWidgets('an All servers location shows its own nav, not Mydia\'s',
      (tester) async {
    await _pump(tester, '/all/movies');
    for (final key in ['home', 'movies', 'shows', 'search']) {
      expect(find.byKey(ValueKey('all-nav-$key')), findsOneWidget);
    }
    expect(
        tester
            .widget<SidebarRow>(find.byKey(const ValueKey('all-nav-movies')))
            .isSelected,
        isTrue);
    expect(
        tester
            .widget<SidebarRow>(find.byKey(const ValueKey('all-nav-home')))
            .isSelected,
        isFalse);
    expect(find.text('Calendar'), findsNothing);
    expect(find.text('+ New filter'), findsNothing);
    expect(find.byTooltip('Edit sidebar'), findsNothing);
    expect(find.byType(SidebarEditBar), findsNothing);
  });

  testWidgets('no Search row for a source that is not searchable',
      (tester) async {
    await _pump(tester, root, editing: false, source: _NotSearchable());
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Search'), findsNothing);
  });

  testWidgets('lists home, search, each library and settings', (tester) async {
    final navigations =
        await _pump(tester, '$root/library/movies', editing: false);
    expect(find.text('Movies'), findsOneWidget);
    expect(find.text('TV Shows'), findsOneWidget);
    await tester.tap(find.text('TV Shows'));
    await tester.tap(find.text('Home'));
    await tester.tap(find.text('Search'));
    await tester.tap(find.text('Settings'));
    expect(navigations, [
      '$root/library/shows',
      root,
      '$root/search',
      '/settings',
    ]);
  });

  testWidgets('no Settings row without a Mydia account', (tester) async {
    // `/settings` redirects back to the source's home without Mydia.
    await _pump(tester, root, editing: false, hasMydia: false);
    expect(find.text('Settings'), findsNothing);
  });

  testWidgets('Settings sits below the libraries', (tester) async {
    await _pump(tester, root, editing: false);
    final settingsTop = tester.getTopLeft(find.text('Settings')).dy;
    expect(tester.getTopLeft(find.text('TV Shows')).dy, lessThan(settingsTop));
  });

  group('the shell focus node', () {
    bool attachedTo(FocusNode node, String label) {
      final context = node.context;
      if (context == null) return false;
      var found = false;
      context.visitAncestorElements((e) {
        final w = e.widget;
        if (w is SidebarRow && w.label == label) found = true;
        return !found;
      });
      return found;
    }

    testWidgets('sits on the row for the current location', (tester) async {
      final node = FocusNode();
      addTearDown(node.dispose);
      await _pump(tester, '$root/library/shows',
          editing: false, focusNode: node);
      expect(attachedTo(node, 'TV Shows'), isTrue);
      expect(attachedTo(node, 'Home'), isFalse);
    });

    testWidgets('falls back to the first row when no row matches',
        (tester) async {
      final node = FocusNode();
      addTearDown(node.dispose);
      await _pump(tester, '$root/item/x', editing: false, focusNode: node);
      expect(attachedTo(node, 'Search'), isTrue);
    });
  });

  testWidgets('positive control: a Mydia location keeps both', (tester) async {
    await _pump(tester, '/');
    expect(find.byTooltip('Edit sidebar'), findsOneWidget);
    expect(find.byType(SidebarEditBar), findsOneWidget);
  });
}
