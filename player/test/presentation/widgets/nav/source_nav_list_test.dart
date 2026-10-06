import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/presentation/widgets/nav/source_nav_list.dart';

import '../../screens/sources/fake_media_source.dart';

class _NotSearchable extends FakeMediaSource {
  @override
  T? as<T extends Object>() => null;
}

Future<List<String>> _pump(
  WidgetTester tester, {
  FakeMediaSource? source,
  bool hasMydia = true,
  String location = '/s/acc1:owner:aa11',
  FocusNode? focusNode,
}) async {
  final navigations = <String>[];
  await tester.pumpWidget(ProviderScope(
    overrides: [
      hasMydiaProvider.overrideWithValue(hasMydia),
      mediaSourceProvider(fakeSourceId)
          .overrideWithValue(source ?? FakeMediaSource()),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: SourceNavList(
          sourceId: fakeSourceId,
          location: location,
          onNavigate: navigations.add,
          selectedRowFocusNode: focusNode,
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return navigations;
}

void main() {
  test('reads the source id out of a location', () {
    expect(sourceIdFromLocation('/s/acc1:owner:aa11/library/movies'),
        'acc1:owner:aa11');
    expect(sourceIdFromLocation('/s/acc1:owner:aa11'), 'acc1:owner:aa11');
    expect(sourceIdFromLocation('/movies'), isNull);
    expect(sourceIdFromLocation('/s/%E0%A4%A/library'), isNull);
  });

  testWidgets('no Search row for a source that is not searchable',
      (tester) async {
    await _pump(tester, source: _NotSearchable());
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Search'), findsNothing);
  });

  testWidgets('lists home, search, each library and settings', (tester) async {
    final navigations =
        await _pump(tester, location: '/s/acc1:owner:aa11/library/movies');
    expect(find.text('Films'), findsOneWidget);
    expect(find.text('Series'), findsOneWidget);
    await tester.tap(find.text('Series'));
    await tester.tap(find.text('Home'));
    await tester.tap(find.text('Search'));
    await tester.tap(find.byKey(const ValueKey('source-nav-settings')));
    expect(navigations, [
      '/s/acc1:owner:aa11/library/shows',
      '/s/acc1:owner:aa11',
      '/s/acc1:owner:aa11/search',
      '/settings',
    ]);
  });

  testWidgets('the header replaces the Servers row', (tester) async {
    await _pump(tester);
    expect(find.byKey(const ValueKey('source-nav-servers')), findsNothing);
    expect(find.text('Servers'), findsNothing);
  });

  testWidgets('no Settings row without a Mydia account', (tester) async {
    // `/settings` redirects back to the source's home without Mydia.
    await _pump(tester, hasMydia: false);
    expect(find.byKey(const ValueKey('source-nav-settings')), findsNothing);
  });

  testWidgets('Settings sits below the libraries', (tester) async {
    await _pump(tester);
    final settingsTop =
        tester.getTopLeft(find.byKey(const ValueKey('source-nav-settings'))).dy;
    expect(tester.getTopLeft(find.text('Series')).dy, lessThan(settingsTop));
  });

  group('the shell focus node', () {
    // Which row's subtree holds the node's context.
    bool attachedTo(FocusNode node, String rowKey) {
      final context = node.context;
      if (context == null) return false;
      var found = false;
      context.visitAncestorElements((e) {
        if (e.widget.key == ValueKey(rowKey)) found = true;
        return !found;
      });
      return found;
    }

    testWidgets('sits on the row for the current location', (tester) async {
      final node = FocusNode();
      addTearDown(node.dispose);
      await _pump(tester,
          location: '/s/acc1:owner:aa11/library/shows', focusNode: node);
      expect(attachedTo(node, 'source-nav-library-shows'), isTrue);
      expect(attachedTo(node, 'source-nav-home'), isFalse);
    });

    testWidgets('falls back to Home when no row matches', (tester) async {
      final node = FocusNode();
      addTearDown(node.dispose);
      await _pump(tester,
          location: '/s/acc1:owner:aa11/item/x', focusNode: node);
      expect(attachedTo(node, 'source-nav-home'), isTrue);
    });
  });
}
