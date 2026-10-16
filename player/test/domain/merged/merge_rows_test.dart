import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/merged/merge_rows.dart';
import 'package:player/domain/sources/item.dart';

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
}
