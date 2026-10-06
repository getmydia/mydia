import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/capabilities.dart';
import 'package:player/core/sources/media_source.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/domain/sources/item.dart';

void main() {
  const ref = ItemRef(
    sourceId: SourceId('a:owner:s'),
    kind: ItemKind.movie,
    externalId: '1',
  );

  test('new detail fields default to empty', () {
    const detail = ItemDetail(
      summary: ItemSummary(ref: ref, title: 'Saltwater Clocks'),
    );
    expect(detail.cast, isEmpty);
    expect(detail.isFavorite, isFalse);
    expect(detail.trailerUrl, isNull);
    expect(detail.contentRating, isNull);
    expect(detail.show, isNull);
    expect(detail.season, isNull);
  });

  test('new summary fields default to null', () {
    const summary = ItemSummary(ref: ref, title: 'Saltwater Clocks');
    expect(summary.overview, isNull);
    expect(summary.airDate, isNull);
    expect(summary.defaultVersionId, isNull);
  });

  test('a person carries a role and a photo', () {
    const p = Person(
      name: 'Ana Bergström',
      role: 'Kira',
      photo: ArtworkRef('/p/1'),
    );
    expect(p.role, 'Kira');
    expect(p.photo, const ArtworkRef('/p/1'));
  });

  test('capabilities for similar, favorites and next up exist', () {
    expect(
      SourceCapability.values,
      containsAll([
        SourceCapability.similar,
        SourceCapability.favorites,
        SourceCapability.nextUp,
      ]),
    );
    // The interfaces are referenced so a rename breaks this test.
    expect(Similar, isNotNull);
    expect(Favorites, isNotNull);
    expect(NextUp, isNotNull);
  });

  test('MediaVersion round-trips size and HDR, and reads old entries', () {
    const v = MediaVersion(id: 'f1', sizeBytes: 4200000000, hdrFormat: 'HDR10');
    final back = MediaVersion.fromJson(v.toJson());
    expect(back.sizeBytes, 4200000000);
    expect(back.hdrFormat, 'HDR10');
    final old = MediaVersion.fromJson(const {'id': 'f1'});
    expect(old.sizeBytes, isNull);
    expect(old.hdrFormat, isNull);
  });
}
