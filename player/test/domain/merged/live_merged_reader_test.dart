import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/domain/merged/merged_library_reader.dart';
import 'package:player/domain/merged/merged_search.dart';
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
}
