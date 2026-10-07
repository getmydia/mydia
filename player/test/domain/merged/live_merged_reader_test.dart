import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/domain/merged/merged_library_reader.dart';
import 'package:player/domain/merged/merged_search.dart';
import 'package:player/domain/sources/collection.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/domain/sources/source_error.dart';

import 'fake_merged_source.dart';

void main() {
  test('continue watching merges by last played, capped at 20', () async {
    final a = fakeServer('a'), b = fakeServer('b');
    final t = DateTime.utc(2024);
    final r = await LiveMergedReader([
      FakeMergedSource(a, resuming: [item(a, 'a1', lastPlayedAt: t)]),
      FakeMergedSource(b, resuming: [
        for (var i = 0; i < 25; i++)
          item(b, 'b$i', lastPlayedAt: t.add(Duration(hours: i + 1)))
      ]),
    ]).continueWatching();
    expect(r.value, hasLength(20));
    expect(r.value.first.ref.externalId, 'b24');
    expect(r.value.map((i) => i.ref.externalId), isNot(contains('a1')));
  });

  test('recently added: missing capability is skipped, failure unavailable',
      () async {
    final a = fakeServer('a'), b = fakeServer('b'), c = fakeServer('c');
    final r = await LiveMergedReader([
      FakeMergedSource(a, recent: [item(a, 'a1', addedAt: DateTime.utc(2024))]),
      FakeMergedSource(b, caps: const {}),
      FakeMergedSource(c)..failWith = const SourceException.unreachable(),
    ]).recentlyAdded();
    expect(r.value.map((i) => i.ref.externalId), ['a1']);
    expect(r.skipped, [SourceId(b.id.value)]);
    expect(r.unavailable, [SourceId(c.id.value)]);
  });

  test('search sections by kind and interleaves servers round-robin', () async {
    final a = fakeServer('a'), b = fakeServer('b');
    final r = await LiveMergedReader([
      FakeMergedSource(a, found: [
        item(a, 'am1'),
        item(a, 'am2'),
        item(a, 'as1', kind: ItemKind.show),
      ]),
      FakeMergedSource(b, found: [
        item(b, 'bm1'),
        item(b, 'be1', kind: ItemKind.episode),
      ]),
    ]).search('invented');
    final s = r.value.sections;
    expect(s.keys,
        [MergedSection.movies, MergedSection.shows, MergedSection.episodes]);
    expect(s[MergedSection.movies]!.map((i) => i.ref.externalId),
        ['am1', 'bm1', 'am2']);
  });

  test('every server failing still answers, all unavailable', () async {
    final a = FakeMergedSource(fakeServer('a'))
      ..failWith = const SourceException.unreachable();
    final r = await LiveMergedReader([a]).continueWatching();
    expect(r.value, isEmpty);
    expect(r.unavailable, [a.id]);
  });

  test('rows and search show one card per title', () async {
    final a = fakeServer('a'), b = fakeServer('b');
    const ids = ExternalIds(tmdb: '9');
    final t = DateTime.utc(2024);
    final reader = LiveMergedReader([
      FakeMergedSource(a,
          resuming: [item(a, 'a1', ids: ids, lastPlayedAt: t)],
          found: [item(a, 'a1', ids: ids)]),
      FakeMergedSource(b, resuming: [
        item(b, 'b1',
            ids: ids,
            progress: 60,
            lastPlayedAt: t.add(const Duration(hours: 1)))
      ], found: [
        item(b, 'b1', ids: ids)
      ]),
    ]);
    final cw = await reader.continueWatching();
    expect(cw.value.map((i) => i.ref.externalId), ['b1']);
    expect(cw.extraCopies, {cw.value.single.ref: 1});
    final s = await reader.search('invented');
    expect(s.value.sections[MergedSection.movies], hasLength(1));
    expect(s.extraCopies, hasLength(1));
  });

  test('the 20-item cap applies after duplicates collapse', () async {
    final a = fakeServer('a'), b = fakeServer('b');
    final t = DateTime.utc(2024);
    List<ItemSummary> twenty(Source s) => [
          for (var i = 0; i < 20; i++)
            item(s, '${s.id.value}$i',
                ids: ExternalIds(tmdb: '$i'),
                lastPlayedAt: t.add(Duration(minutes: i + 1)))
        ];
    final cw = await LiveMergedReader([
      FakeMergedSource(a, resuming: twenty(a)),
      FakeMergedSource(b,
          resuming: [...twenty(b), item(b, 'oldest', lastPlayedAt: t)]),
    ]).continueWatching();
    expect(cw.value, hasLength(20));
    // Twenty distinct titles: no title used two places.
    expect(cw.value.map((i) => i.externalIds.tmdb).toSet(), hasLength(20));
  });

  test('favorites pages every server, dedupes and sorts by title', () async {
    final a = fakeServer('a'), b = fakeServer('b');
    final r = await LiveMergedReader([
      FakeMergedSource(a, favPageSize: 1, favs: [
        item(a, 'a1', title: 'Zephyr Lane'),
        item(a, 'a2', title: 'Amber Coast', ids: const ExternalIds(tmdb: '3')),
      ]),
      FakeMergedSource(b, favs: [
        item(b, 'b1', title: 'Amber Coast', ids: const ExternalIds(tmdb: '3')),
        item(b, 'b2', title: 'Moss Hollow'),
      ]),
    ]).favorites();
    expect(r.value.map((i) => i.title),
        ['Amber Coast', 'Moss Hollow', 'Zephyr Lane']);
    expect(r.extraCopies.values.single, 1);
  });

  test('favorites stops at the per-server cap', () async {
    final a = fakeServer('a');
    final r = await LiveMergedReader([
      FakeMergedSource(a, favPageSize: 2, favs: [
        for (var i = 0; i < 9; i++) item(a, 'a$i'),
      ]),
    ]).favorites(perSourceCap: 3);
    expect(r.value, hasLength(3));
  });

  test('collections list every server in order; a failure is unavailable',
      () async {
    final a = fakeServer('a'), b = fakeServer('b');
    final r = await LiveMergedReader([
      FakeMergedSource(a, cols: [
        SourceCollection(sourceId: a.id, id: 'c1', name: 'Invented Saga'),
      ]),
      FakeMergedSource(b)..failWith = const SourceException.unreachable(),
    ]).collections();
    expect(r.value.map((c) => c.id), ['c1']);
    expect(r.unavailable, [b.id]);
  });
}
