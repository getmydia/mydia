import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:player/core/sources/media_source.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/domain/sources/library.dart';
import 'package:player/presentation/screens/all_servers/all_servers_grid_screen.dart';
import 'package:player/presentation/widgets/source_artwork.dart';

import '../../../domain/merged/fake_merged_source.dart';
import '../../../test_utils/toast_harness.dart';

Future<void> pump(WidgetTester tester,
    {required LibraryKind kind, required List<MediaSource> sources}) async {
  final router = GoRouter(routes: [
    GoRoute(path: '/', builder: (_, __) => AllServersGridScreen(kind: kind)),
  ]);
  await tester.binding.setSurfaceSize(const Size(1280, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(ProviderScope(
    overrides: [
      allServersSourcesProvider.overrideWithValue(sources),
      sourcesProvider.overrideWithValue([for (final s in sources) s.source]),
      allServersNeedSignInProvider.overrideWithValue(const []),
      sourceArtworkProvider.overrideWith((ref, key) async => null),
    ],
    child: MaterialApp.router(routerConfig: router, builder: toastLayerBuilder),
  ));
  await tester.pumpAndSettle();
}

const _withReleased = [
  SortOption(id: 'title', label: 'Title', shared: SharedSort.title),
  SortOption(
      id: 'added',
      label: 'Added',
      descendingByDefault: true,
      shared: SharedSort.added),
  SortOption(
      id: 'released',
      label: 'Released',
      descendingByDefault: true,
      shared: SharedSort.released),
];

void main() {
  testWidgets('interleaves servers and offers the three shared sorts',
      (t) async {
    final sa = fakeServer('a'), sb = fakeServer('b');
    final a = FakeMergedSource(sa, sorts: _withReleased, movies: [
      item(sa, 'apple', sortTitle: 'apple'),
      item(sa, 'cherry', sortTitle: 'cherry'),
    ]);
    final b = FakeMergedSource(sb, sorts: _withReleased, movies: [
      item(sb, 'banana', sortTitle: 'banana'),
    ]);
    await pump(t, kind: LibraryKind.movies, sources: [a, b]);
    for (final s in SharedSort.values) {
      expect(find.byKey(Key('all-grid-sort-${s.name}')), findsOneWidget);
    }
    final xs = [
      for (final entry in [(a, 'apple'), (b, 'banana'), (a, 'cherry')])
        t
            .getTopLeft(find
                .byKey(ValueKey('all-poster-${entry.$1.id.value}-${entry.$2}')))
            .dx
    ];
    expect(xs, orderedEquals([...xs]..sort()));
    expect(xs.toSet().length, 3);
  });

  testWidgets('a sort a server lacks names it in the note', (t) async {
    final sa = fakeServer('a'), sb = fakeServer('b');
    final a = FakeMergedSource(sa, sorts: _withReleased, movies: [
      item(sa, 'apple', airDate: '2020-01-01'),
    ]);
    // b has no `released` option.
    final b = FakeMergedSource(sb, movies: [item(sb, 'banana')]);
    await pump(t, kind: LibraryKind.movies, sources: [a, b]);
    expect(find.byKey(const Key('all-sort-skipped-note')), findsNothing);
    await t.tap(find.byKey(const Key('all-grid-sort-released')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('all-sort-skipped-note')), findsOneWidget);
    expect(find.textContaining('Server b'), findsOneWidget);
  });
}
