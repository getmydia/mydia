import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/merged/merge_rows.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/domain/sources/ranked_item.dart';

import 'fake_merged_source.dart';

void main() {
  final a = fakeServer('a'), b = fakeServer('b');
  final order = [a.id, b.id];

  test('newest first across servers, undated last', () {
    final d = mergeNewest([
      [item(a, 'a1', lastPlayedAt: DateTime.utc(2024, 1, 1)), item(a, 'a2')],
      [item(b, 'b1', lastPlayedAt: DateTime.utc(2024, 1, 2))],
    ], order, (i) => i.lastPlayedAt);
    expect(d.items.map((i) => i.ref.externalId), ['b1', 'a1', 'a2']);
  });

  test('copies collapse before the cap and are counted', () {
    const ids = ExternalIds(tmdb: '7');
    final d = mergeNewest([
      [
        item(a, 'a1', ids: ids, addedAt: DateTime.utc(2024, 1, 3)),
        item(a, 'a2', addedAt: DateTime.utc(2024, 1, 1)),
      ],
      [item(b, 'b1', ids: ids, addedAt: DateTime.utc(2024, 1, 2))],
    ], order, (i) => i.addedAt, limit: 2);
    expect(d.items.map((i) => i.ref.externalId), ['a1', 'a2']);
    expect(d.extraCopies[d.items.first.ref], 1);
  });

  test('alphabetical by sort title, ties in server then row order', () {
    final d = mergeAlphabetical([
      [item(a, 'a1', title: 'Zed'), item(a, 'a2', title: 'Same')],
      [item(b, 'b1', title: 'Same'), item(b, 'b2', title: 'Able')],
    ], order);
    expect(d.items.map((i) => i.ref.externalId), ['b2', 'a2', 'b1', 'a1']);
  });

  test('mergeRanked orders globally and dedupes', () {
    const ids = ExternalIds(tmdb: '9');
    final d = mergeRanked([
      [
        RankedItem(item: item(a, 'a1'), rank: 1),
        RankedItem(item: item(a, 'a4', ids: ids), rank: 4),
      ],
      [
        RankedItem(item: item(b, 'b2'), rank: 2),
        RankedItem(item: item(b, 'b4', ids: ids), rank: 4),
      ],
    ], order);
    expect(d.items.map((i) => i.ref.externalId), ['a1', 'b2', 'a4']);
    expect(d.extraCopies[d.items.last.ref], 1);
  });

  test('mergeRanked ties go to server order and honours the limit', () {
    final d = mergeRanked([
      [RankedItem(item: item(a, 'a1'), rank: 1)],
      [RankedItem(item: item(b, 'b1'), rank: 1)],
    ], order, limit: 1);
    expect(d.items.map((i) => i.ref.externalId), ['a1']);
  });
}
