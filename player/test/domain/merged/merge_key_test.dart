import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/merged/merge_key.dart';
import 'package:player/domain/sources/item.dart';

import 'fake_merged_source.dart';

void main() {
  final a = fakeServer('a'), b = fakeServer('b'), c = fakeServer('c');
  final order = [a.id, b.id, c.id];

  test('copies sharing any one id collapse to the first position', () {
    final d = dedupe([
      item(a, 'a1', ids: const ExternalIds(tmdb: '7')),
      item(a, 'a2'),
      item(b, 'b1', ids: const ExternalIds(tmdb: '7', imdb: 'tt7')),
    ], order);
    expect(d.items.map((i) => i.ref.externalId), ['a1', 'a2']);
    expect(d.extraCopies, {d.items.first.ref: 1});
  });

  test('a different kind never matches', () {
    final d = dedupe([
      item(a, 'm', ids: const ExternalIds(tmdb: '7')),
      item(b, 's', kind: ItemKind.show, ids: const ExternalIds(tmdb: '7')),
    ], order);
    expect(d.items, hasLength(2));
    expect(d.extraCopies, isEmpty);
  });

  test('matching is transitive across different ids', () {
    final d = dedupe([
      item(a, 'a1', ids: const ExternalIds(tmdb: '1')),
      item(b, 'b1', ids: const ExternalIds(tmdb: '1', imdb: 'tt1')),
      item(c, 'c1', ids: const ExternalIds(imdb: 'tt1')),
    ], order);
    expect(d.items, hasLength(1));
    expect(d.extraCopies.values.single, 2);
  });

  test('the copy with more progress is kept, else the earlier server', () {
    final withProgress = dedupe([
      item(a, 'a1', ids: const ExternalIds(tmdb: '1')),
      item(b, 'b1', ids: const ExternalIds(tmdb: '1'), progress: 300),
    ], order);
    expect(withProgress.items.single.ref.externalId, 'b1');

    final byOrder = dedupe([
      item(b, 'b1', ids: const ExternalIds(tmdb: '1')),
      item(a, 'a1', ids: const ExternalIds(tmdb: '1')),
    ], order);
    expect(byOrder.items.single.ref.externalId, 'a1');
  });

  test('items without ids are never merged', () {
    final d = dedupe([item(a, 'x'), item(b, 'x')], order);
    expect(d.items, hasLength(2));
  });
}
