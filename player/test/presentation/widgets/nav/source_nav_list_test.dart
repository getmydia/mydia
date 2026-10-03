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
    await tester.pumpWidget(ProviderScope(
      overrides: [
        mediaSourceProvider(fakeSourceId).overrideWithValue(_NotSearchable())
      ],
      child: MaterialApp(
        home: Scaffold(
          body: SourceNavList(
            sourceId: fakeSourceId,
            location: '/s/acc1:owner:aa11',
            onNavigate: (_) {},
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Search'), findsNothing);
  });

  testWidgets('lists home, search, each library and servers', (tester) async {
    final navigations = <String>[];
    await tester.pumpWidget(ProviderScope(
      overrides: [
        mediaSourceProvider(fakeSourceId).overrideWithValue(FakeMediaSource())
      ],
      child: MaterialApp(
        home: Scaffold(
          body: SourceNavList(
            sourceId: fakeSourceId,
            location: '/s/acc1:owner:aa11/library/movies',
            onNavigate: navigations.add,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Films'), findsOneWidget);
    expect(find.text('Series'), findsOneWidget);
    await tester.tap(find.text('Series'));
    await tester.tap(find.text('Home'));
    await tester.tap(find.text('Search'));
    await tester.tap(find.text('Servers'));
    expect(navigations, [
      '/s/acc1:owner:aa11/library/shows',
      '/s/acc1:owner:aa11',
      '/s/acc1:owner:aa11/search',
      '/sources/manage',
    ]);
  });
}
