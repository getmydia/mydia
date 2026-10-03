import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/domain/sources/library.dart';
import 'package:player/domain/sources/source_error.dart';

void main() {
  const plex = SourceId('acc1:owner:srv9');

  test('ItemRef compares by source, kind and id', () {
    const a = ItemRef(sourceId: plex, kind: ItemKind.movie, externalId: '42');
    const b = ItemRef(sourceId: plex, kind: ItemKind.movie, externalId: '42');
    const c = ItemRef(sourceId: plex, kind: ItemKind.episode, externalId: '42');
    expect(a, b);
    expect(a.hashCode, b.hashCode);
    expect(a == c, isFalse);
  });

  test('LibraryRef and ArtworkRef compare by value', () {
    expect(const LibraryRef(sourceId: plex, id: '1'),
        const LibraryRef(sourceId: plex, id: '1'));
    expect(const ArtworkRef('/library/metadata/1/thumb/9'),
        const ArtworkRef('/library/metadata/1/thumb/9'));
  });

  test('BrowseQuery compares by value and copies', () {
    const q = BrowseQuery(sortId: 'titleSort', filterIds: {'unwatched'});
    expect(q, const BrowseQuery(sortId: 'titleSort', filterIds: {'unwatched'}));
    expect(q.copyWith(descending: true).descending, isTrue);
    expect(q.copyWith(descending: true).sortId, 'titleSort');
  });

  test('Page knows whether more remain', () {
    expect(const Page<int>(items: [1]).hasMore, isFalse);
    expect(
        const Page<int>(items: [1], nextCursor: Cursor('60')).hasMore, isTrue);
  });

  test('SourceException speaks to the viewer', () {
    expect(
        const SourceException.unreachable().viewerMessage, contains('reach'));
    expect(const SourceException.unauthorized().viewerMessage,
        contains('Sign in again'));
    expect(const SourceException.server('Transcoder busy').viewerMessage,
        'Transcoder busy');
  });
}
