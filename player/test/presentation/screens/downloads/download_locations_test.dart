import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/models/download.dart';
import 'package:player/presentation/screens/downloads/download_locations.dart';

import '../../../test_utils/mydia_test_source.dart';

DownloadedMedia _m({
  String mediaId = '42',
  String? sourceId,
  String mediaType = 'movie',
  String? itemKind,
  int? season,
}) =>
    DownloadedMedia(
      id: 'r',
      mediaId: mediaId,
      title: 'Quill Harbor',
      quality: 'original',
      filePath: '/f',
      fileSize: 1,
      downloadedAt: DateTime(2026),
      mediaType: mediaType,
      sourceId: sourceId,
      itemKind: itemKind,
      showId: season == null ? null : 's1',
      seasonNumber: season,
    );

void main() {
  test('a Mydia account plays through its own player route too', () {
    expect(
      downloadedPlayLocation(_m(sourceId: testMydiaSourceId.value)),
      '/s/macct:owner:inst-1/player/42?kind=movie&fileId=offline'
      '&title=Quill+Harbor',
    );
    expect(
      downloadedPlayLocation(_m(
          sourceId: testMydiaSourceId.value, mediaType: 'episode', season: 2)),
      '/s/macct:owner:inst-1/player/42?kind=episode&fileId=offline'
      '&title=Quill+Harbor&showId=s1&seasonNumber=2',
    );
  });

  test('a source plays through its own player route', () {
    expect(
      downloadedPlayLocation(
          _m(sourceId: 'acc1:owner:aa11', itemKind: 'video')),
      '/s/acc1:owner:aa11/player/42?kind=video&fileId=offline'
      '&title=Quill+Harbor',
    );
  });

  test('an item id with a slash stays one path segment', () {
    final location = downloadedPlayLocation(
        _m(mediaId: 'a/b', sourceId: 'acc1:owner:aa11', itemKind: 'video'));
    expect(location, startsWith('/s/acc1:owner:aa11/player/a%2Fb?'));
    expect(Uri.parse(location).pathSegments.last, 'a/b');
  });

  test('a source id with a space is encoded once', () {
    final location = downloadedPlayLocation(
        _m(mediaId: 'a b', sourceId: 'acc1:owner:aa11', itemKind: 'video'));
    expect(location, startsWith('/s/acc1:owner:aa11/player/a%20b?'));
    expect(Uri.parse(location).pathSegments.last, 'a b');
  });
}
