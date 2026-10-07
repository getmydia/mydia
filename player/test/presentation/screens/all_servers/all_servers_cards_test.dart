import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/domain/sources/library.dart';
import 'package:player/presentation/screens/all_servers/all_servers_cards.dart';

import '../../../test_utils/mydia_test_source.dart';

void main() {
  test('every server, Mydia included, opens its source route', () {
    expect(
        allServersItemLocation(const ItemRef(
            sourceId: testMydiaSourceId,
            kind: ItemKind.movie,
            externalId: '42')),
        '/s/macct:owner:inst-1/movie/42');
    expect(
        allServersItemLocation(const ItemRef(
            sourceId: SourceId('acc1:owner:aa11'),
            kind: ItemKind.movie,
            externalId: '7')),
        '/s/acc1:owner:aa11/movie/7');
  });

  test('a kind without a detail screen falls back to the item route', () {
    expect(
        allServersItemLocation(const ItemRef(
            sourceId: testMydiaSourceId,
            kind: ItemKind.video,
            externalId: '9')),
        '/s/macct:owner:inst-1/item/video/9');
  });

  test('library locations', () {
    expect(allServersLibraryLocation(LibraryKind.movies), '/all/movies');
    expect(allServersLibraryLocation(LibraryKind.shows), '/all/shows');
    expect(allServersRoot, '/all');
    expect(allServersSearchLocation, '/all/search');
  });

  test('fewer than two included sources redirect home', () {
    expect(allServersRedirect(0), '/');
    expect(allServersRedirect(1), '/');
    expect(allServersRedirect(2), isNull);
  });

  test('a merged card names its server with +N', () {
    expect(allServersServerLabel('Server a', 0), 'Server a');
    expect(allServersServerLabel('Server a', 2), 'Server a +2');
    expect(allServersServerLabel(null, 2), isNull);
  });

  test('the new merged locations', () {
    expect(allServersFavoritesLocation, '/all/favorites');
    expect(isAllServersLocation('/all'), isTrue);
    expect(isAllServersLocation('/all/collections'), isTrue);
    expect(isAllServersLocation('/allx'), isFalse);
  });
}
