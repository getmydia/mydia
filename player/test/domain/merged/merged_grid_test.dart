import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/merged/merged_library_reader.dart';
import 'package:player/domain/sources/library.dart';
import 'package:player/domain/sources/source_error.dart';

import 'fake_merged_source.dart';

void main() {
  LiveMergedReader reader(List<FakeMergedSource> s) => LiveMergedReader(s,
      timeout: const Duration(milliseconds: 200), pageSize: 2);

  test('interleaves three sorted streams exactly, across pages', () async {
    final a = fakeServer('a'), b = fakeServer('b'), c = fakeServer('c');
    final grid = await reader([
      FakeMergedSource(a, movies: [
        for (final t in ['b', 'e', 'h']) item(a, t, title: t)
      ]),
      FakeMergedSource(b, movies: [
        for (final t in ['a', 'd', 'g']) item(b, t, title: t)
      ]),
      FakeMergedSource(c, movies: [
        for (final t in ['c', 'f', 'i']) item(c, t, title: t)
      ]),
    ]).grid(LibraryKind.movies, SharedSort.title);
    await grid.loadMore(count: 4);
    expect(grid.items.map((i) => i.title), ['a', 'b', 'c', 'd']);
    await grid.loadMore(count: 10);
    expect(grid.items.map((i) => i.title),
        ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i']);
    expect(grid.hasMore, isFalse);
  });

  test('asks each library for its own option id and the shared direction',
      () async {
    final a = FakeMergedSource(fakeServer('a'),
        movies: [item(fakeServer('a'), '1', addedAt: DateTime.utc(2024))]);
    final grid = await reader([a]).grid(LibraryKind.movies, SharedSort.added);
    await grid.loadMore();
    expect(a.browseCalls.first.sortId, 'added');
    expect(a.browseCalls.first.descending, isTrue);
  });

  test('a server without the sort is skipped, one that fails is unavailable',
      () async {
    final noSort = FakeMergedSource(fakeServer('n'),
        movies: [item(fakeServer('n'), '1')], sorts: const []);
    final down = FakeMergedSource(fakeServer('d'))
      ..failWith = const SourceException.unreachable();
    final ok = FakeMergedSource(fakeServer('o'),
        movies: [item(fakeServer('o'), '1', title: 'x')]);
    final grid = await reader([noSort, down, ok])
        .grid(LibraryKind.movies, SharedSort.title);
    await grid.loadMore();
    expect(grid.skipped, [noSort.id]);
    expect(grid.unavailable, [down.id]);
    expect(grid.items, hasLength(1));
  });

  test('a stream failing mid-scroll stops; emitted items stay', () async {
    final a = fakeServer('a'), b = fakeServer('b');
    final flaky = FakeMergedSource(a, movies: [
      for (final t in ['a', 'c', 'e', 'g']) item(a, t, title: t)
    ])
      ..failAfterPages = 1;
    final steady = FakeMergedSource(b, movies: [
      for (final t in ['b', 'd', 'f']) item(b, t, title: t)
    ]);
    final grid = await reader([flaky, steady])
        .grid(LibraryKind.movies, SharedSort.title);
    await grid.loadMore(count: 3);
    expect(grid.items.map((i) => i.title), ['a', 'b', 'c']);
    await grid.loadMore(count: 10);
    expect(grid.items.map((i) => i.title), ['a', 'b', 'c', 'd', 'f']);
    expect(grid.unavailable, [flaky.id]);
  });

  test('a server slower than the timeout is unavailable', () async {
    final slow = FakeMergedSource(fakeServer('s'))..gate = Completer<void>();
    addTearDown(() => slow.gate!.complete());
    final grid =
        await reader([slow]).grid(LibraryKind.movies, SharedSort.title);
    expect(grid.unavailable, [slow.id]);
  });
}
