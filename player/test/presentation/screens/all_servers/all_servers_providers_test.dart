import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/domain/merged/merged_grid.dart';
import 'package:player/domain/merged/merged_library_reader.dart';
import 'package:player/domain/merged/merged_result.dart';
import 'package:player/domain/merged/merged_search.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/domain/sources/library.dart';
import 'package:player/presentation/screens/all_servers/all_servers_providers.dart';

import '../../../domain/merged/fake_merged_source.dart';

const _sorts = [
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

/// More than one build's worth, so `hasMore` stays true after the first load.
FakeMergedSource bigServer() {
  final s = fakeServer('a');
  return FakeMergedSource(s, sorts: _sorts, movies: [
    for (var i = 0; i < 130; i++)
      item(s, 'm${i.toString().padLeft(3, '0')}',
          sortTitle: 'm${i.toString().padLeft(3, '0')}'),
  ]);
}

ProviderContainer containerFor(FakeMergedSource source,
    {MergedLibraryReader? reader}) {
  final c = ProviderContainer(overrides: [
    allServersSourcesProvider.overrideWithValue([source]),
    if (reader != null) allServersReaderProvider.overrideWithValue(reader),
  ]);
  addTearDown(c.dispose);
  return c;
}

class ThrowingGrid extends MergedGrid {
  ThrowingGrid()
      : super(const [],
            sort: SharedSort.title, descending: false, timeout: Duration.zero);

  int calls = 0;
  @override
  bool get hasMore => true;

  @override
  Future<void> loadMore({int count = 60}) async {
    if (calls++ > 0) throw StateError('boom');
  }
}

class ScriptedReader implements MergedLibraryReader {
  ScriptedReader({this.gridFor});

  final MergedGrid Function()? gridFor;
  final searches = <String>[];
  final completers = <String, Completer<MergedResult<MergedSearch>>>{};

  @override
  Future<MergedGrid> grid(LibraryKind kind, SharedSort sort,
          {bool? descending}) async =>
      gridFor!();

  @override
  Future<MergedResult<MergedSearch>> search(String query) {
    searches.add(query);
    return (completers[query] ??= Completer()).future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  group('grid notifier', () {
    test('a sort change while loadMore is in flight wins', () async {
      final src = bigServer();
      final c = containerFor(src);
      final sub =
          c.listen(allServersGridProvider(LibraryKind.movies), (_, __) {});
      addTearDown(sub.close);
      final p = allServersGridProvider(LibraryKind.movies);
      await c.read(p.future);
      expect(c.read(p).requireValue.items.length, 60);

      src.gate = Completer<void>();
      final paging = c.read(p.notifier).loadMore();
      await settle();
      c.read(p.notifier).setSort(SharedSort.added);
      src.gate!.complete();
      await paging;
      await c.read(p.future);
      await settle();

      final s = c.read(p).requireValue;
      expect(s.sort, SharedSort.added);
      expect(s.items.length, 60);
      expect(s.loadingMore, isFalse);
    });

    test('loadMore failure clears loadingMore', () async {
      final grid = ThrowingGrid();
      final c = containerFor(bigServer(),
          reader: ScriptedReader(gridFor: () => grid));
      final p = allServersGridProvider(LibraryKind.movies);
      final sub = c.listen(p, (_, __) {});
      addTearDown(sub.close);
      await c.read(p.future);
      await c.read(p.notifier).loadMore();
      final s = c.read(p).requireValue;
      expect(s.loadingMore, isFalse);
      expect(s.hasMore, isTrue);
    });

    test('two quick setSort calls end on the second and page that sort',
        () async {
      final src = bigServer();
      final c = containerFor(src);
      final p = allServersGridProvider(LibraryKind.movies);
      final sub = c.listen(p, (_, __) {});
      addTearDown(sub.close);
      await c.read(p.future);

      src.gate = Completer<void>();
      c.read(p.notifier).setSort(SharedSort.added);
      await settle();
      c.read(p.notifier).setSort(SharedSort.released);
      await settle();
      src.gate!.complete();
      await settle();
      await c.read(p.future);
      await settle();

      expect(c.read(p).requireValue.sort, SharedSort.released);
      await c.read(p.notifier).loadMore();
      final s = c.read(p).requireValue;
      expect(s.sort, SharedSort.released);
      expect(s.items.length, 120);
    });

    test('loadMore does nothing while a reload is pending', () async {
      final src = bigServer();
      final c = containerFor(src);
      final p = allServersGridProvider(LibraryKind.movies);
      final sub = c.listen(p, (_, __) {});
      addTearDown(sub.close);
      await c.read(p.future);

      src.gate = Completer<void>();
      c.read(p.notifier).setSort(SharedSort.added);
      await c.read(p.notifier).loadMore();
      src.gate!.complete();
      await settle();
      await c.read(p.future);
      expect(c.read(p).requireValue.sort, SharedSort.added);
      expect(c.read(p).requireValue.items.length, 60);
    });
  });

  group('search notifier', () {
    MergedResult<MergedSearch> result(String title) {
      final s = fakeServer('a');
      return MergedResult(MergedSearch({
        MergedSection.movies: [item(s, title, kind: ItemKind.movie)],
      }));
    }

    Future<void> debounce() =>
        Future<void>.delayed(const Duration(milliseconds: 450));

    test('a slow earlier search does not overwrite a newer query', () async {
      final reader = ScriptedReader();
      final c = containerFor(bigServer(), reader: reader);
      final sub = c.listen(allServersSearchProvider, (_, __) {});
      addTearDown(sub.close);
      final n = c.read(allServersSearchProvider.notifier);

      n.query('one');
      await debounce();
      n.query('two');
      await debounce();
      reader.completers['two']!.complete(result('two'));
      await settle();
      reader.completers['one']!.complete(result('one'));
      await settle();

      final shown = c.read(allServersSearchProvider)!.requireValue;
      expect(shown.value.sections[MergedSection.movies]!.single.ref.externalId,
          'two');
    });

    test('retry reruns the last query once, without a second debounced run',
        () async {
      final reader = ScriptedReader();
      final c = containerFor(bigServer(), reader: reader);
      final sub = c.listen(allServersSearchProvider, (_, __) {});
      addTearDown(sub.close);
      final n = c.read(allServersSearchProvider.notifier);

      n.query('x');
      await debounce();
      expect(reader.searches, ['x']);
      n.retry();
      expect(reader.searches, ['x', 'x']);

      n.query('y');
      n.retry();
      await debounce();
      expect(reader.searches, ['x', 'x', 'y']);
    });
  });
}
