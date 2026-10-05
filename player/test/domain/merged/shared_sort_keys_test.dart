import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/merged/shared_sort_keys.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/domain/sources/library.dart';

import 'fake_merged_source.dart';

void main() {
  final a = fakeServer('a'), b = fakeServer('b');

  test('title compares sort title, case-folded, ascending by default', () {
    final x = item(a, '1', title: 'The Zebra Hour', sortTitle: 'Zebra Hour');
    final y = item(b, '2', title: 'apple orchard');
    expect(defaultDescending(SharedSort.title), isFalse);
    expect(
        compareForSort(y, x, SharedSort.title, descending: false), lessThan(0));
  });

  test('missing keys sort last in both directions', () {
    final dated = item(a, '1', addedAt: DateTime.utc(2024));
    final undated = item(a, '2');
    for (final desc in [true, false]) {
      expect(compareForSort(dated, undated, SharedSort.added, descending: desc),
          lessThan(0));
    }
  });

  test('ties break on source id, then external id', () {
    final t = DateTime.utc(2024);
    final x = item(a, '2', addedAt: t), y = item(b, '1', addedAt: t);
    expect(
        compareForSort(x, y, SharedSort.added, descending: true), lessThan(0));
  });

  test('released falls back to the year', () {
    final x = ItemSummary(
        ref: ItemRef(sourceId: a.id, kind: ItemKind.movie, externalId: '1'),
        title: 'X',
        year: 2020);
    final y = item(a, '2', airDate: '2021-05-01');
    expect(compareForSort(y, x, SharedSort.released, descending: true),
        lessThan(0));
  });

  test('newestFirst merges by time, undated last in server order, capped', () {
    final t = DateTime.utc(2024, 1, 1);
    final lists = [
      [item(a, 'a1', lastPlayedAt: t), item(a, 'a2')],
      [
        item(b, 'b1', lastPlayedAt: t.add(const Duration(days: 1))),
        item(b, 'b2')
      ],
    ];
    expect(
        newestFirst(lists, (i) => i.lastPlayedAt).map((i) => i.ref.externalId),
        ['b1', 'a1', 'a2', 'b2']);
    expect(newestFirst(lists, (i) => i.lastPlayedAt, limit: 2), hasLength(2));
  });
}
