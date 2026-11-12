import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/cache/source_codecs.dart';
import 'package:player/core/sources/cache/source_keys.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/domain/sources/ranked_item.dart';

void main() {
  const sid = SourceId('src-1');

  test('ranked items round trip through the cache codec', () {
    final items = [
      for (var i = 1; i <= 2; i++)
        RankedItem(
          item: ItemSummary(
            ref:
                ItemRef(sourceId: sid, kind: ItemKind.show, externalId: 's-$i'),
            title: 'Invented Show $i',
          ),
          rank: i,
        ),
    ];
    final back = decodeRanked(encodeRanked(items));
    expect(back.map((r) => r.rank), [1, 2]);
    expect(back.map((r) => r.item.ref.externalId), ['s-1', 's-2']);
  });

  test('trending keys differ by kind and sit in the trending family', () {
    final movie = SourceKeys.trending(sid, ItemKind.movie);
    final show = SourceKeys.trending(sid, ItemKind.show);
    expect(movie, isNot(show));
    expect(movie.operationName, 'src-1/trending');
  });
}
