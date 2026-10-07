import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/domain/sources/item.dart';

void main() {
  const ref =
      ItemRef(sourceId: SourceId('a'), kind: ItemKind.movie, externalId: '1');

  test('round-trips ids through cache JSON', () {
    const item = ItemSummary(
      ref: ref,
      title: 'The Invented Voyage',
      externalIds: ExternalIds(tmdb: '42', imdb: 'tt0000042'),
    );
    final back = ItemSummary.fromJson(item.toJson());
    expect(back.externalIds, const ExternalIds(tmdb: '42', imdb: 'tt0000042'));
  });

  test('an entry cached before ids existed reads as none', () {
    final json = const ItemSummary(ref: ref, title: 'Old Entry').toJson()
      ..remove('externalIds');
    expect(ItemSummary.fromJson(json).externalIds, ExternalIds.none);
    expect(ExternalIds.none.isEmpty, isTrue);
  });
}
