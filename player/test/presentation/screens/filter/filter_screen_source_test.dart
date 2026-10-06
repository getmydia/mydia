import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/navigation/sidebar_layout_providers.dart';
import 'package:player/core/navigation/sidebar_layout_store.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/domain/navigation/media_filter.dart';
import 'package:player/domain/navigation/nav_destination.dart';
import 'package:player/domain/navigation/sidebar_layout.dart';
import 'package:player/domain/sources/library.dart';
import 'package:player/presentation/screens/filter/filter_screen.dart';
import 'package:player/presentation/screens/library/library_sort.dart';
import 'package:player/presentation/widgets/source_artwork.dart';

import '../sources/fake_capable_source.dart';
import '../sources/fake_media_source.dart';

const _lateShows = FilterDestination(
  id: 'f1',
  label: 'Late Shows',
  filter: MediaFilter(
    kind: MediaKind.shows,
    category: null,
    watch: WatchScope.unwatched,
    sort: LibrarySort.defaultSort,
  ),
);

Future<void> pumpFilter(
  WidgetTester tester,
  FakeMediaSource source, {
  String filterId = 'f1',
}) async {
  await tester.binding.setSurfaceSize(const Size(1280, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final store = InMemorySidebarLayoutStore();
  await store.save(SidebarLayout.defaults.withFilter(_lateShows));
  await tester.pumpWidget(ProviderScope(
    overrides: [
      mediaSourceProvider(fakeSourceId).overrideWithValue(source),
      sidebarLayoutStoreProvider.overrideWithValue(store),
      sourceArtworkProvider.overrideWith((ref, key) async => null),
    ],
    child: MaterialApp(
      home: FilterScreen(sourceId: fakeSourceId, filterId: filterId),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('titles the screen with the filter and browses its query',
      (tester) async {
    final source = FakeCapableSource()
      ..filterQueryResult = (
        library: FakeMediaSource.shows,
        query: const BrowseQuery(filterIds: {'watch:unwatched'}),
      );
    await pumpFilter(tester, source);

    expect(find.text('Late Shows'), findsOneWidget);
    expect(source.browseCalls.first.$1.filterIds, {'watch:unwatched'});
    expect(find.byKey(const ValueKey('source-poster-s1')), findsOneWidget);
  });

  testWidgets('a source with no library for the filter shows not found',
      (tester) async {
    final source = FakeCapableSource()..filterQueryResult = null;
    await pumpFilter(tester, source);

    expect(find.text('This filter no longer exists.'), findsOneWidget);
    expect(source.browseCalls, isEmpty);
  });

  testWidgets('an unknown filter id shows not found', (tester) async {
    await pumpFilter(tester, FakeCapableSource(), filterId: 'missing');

    expect(find.text('This filter no longer exists.'), findsOneWidget);
  });

  testWidgets('a source without saved filters shows not found', (tester) async {
    await pumpFilter(tester, FakeMediaSource());

    expect(find.text('This filter no longer exists.'), findsOneWidget);
  });
}
