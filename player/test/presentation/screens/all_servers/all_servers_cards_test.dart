import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/domain/sources/library.dart';
import 'package:player/presentation/screens/all_servers/all_servers_cards.dart';

import '../../../domain/merged/fake_merged_source.dart';
import '../../../test_utils/mydia_test_source.dart';

void main() {
  test('the bound instance opens Mydia\'s own screen, a source item its route',
      () {
    expect(
        allServersItemLocation(
            const ItemRef(
                sourceId: testMydiaSourceId,
                kind: ItemKind.movie,
                externalId: '42'),
            testMydiaSourceId),
        '/movie/42');
    expect(
        allServersItemLocation(
            const ItemRef(
                sourceId: SourceId('acc1:owner:aa11'),
                kind: ItemKind.movie,
                externalId: '7'),
            testMydiaSourceId),
        '/s/acc1:owner:aa11/movie/7');
    expect(
        allServersItemLocation(
            const ItemRef(
                sourceId: testMydiaSourceId,
                kind: ItemKind.movie,
                externalId: '42'),
            null),
        '/s/macct:owner:inst-1/movie/42',
        reason: 'a Mydia that is not the bound instance uses the source route');
  });

  test('a bound kind without a detail screen falls back to the source route',
      () {
    expect(
        allServersItemLocation(
            const ItemRef(
                sourceId: testMydiaSourceId,
                kind: ItemKind.video,
                externalId: '9'),
            testMydiaSourceId),
        '/s/macct:owner:inst-1/item/video/9');
  });

  test('library locations', () {
    expect(allServersLibraryLocation(LibraryKind.movies), '/all/movies');
    expect(allServersLibraryLocation(LibraryKind.shows), '/all/shows');
    expect(allServersRoot, '/all');
    expect(allServersSearchLocation, '/all/search');
  });

  test('fewer than two included sources redirect home', () {
    FakeMergedSource fake(String id) => FakeMergedSource(fakeServer(id));
    expect(allServersRedirect([]), '/');
    expect(allServersRedirect([fake('a')]), '/');
    expect(allServersRedirect([fake('a'), fake('b')]), isNull);
  });
}
