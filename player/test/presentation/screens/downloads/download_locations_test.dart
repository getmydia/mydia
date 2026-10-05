import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/models/download.dart';
import 'package:player/presentation/screens/downloads/download_locations.dart';

DownloadedMedia _m({
  String? sourceId,
  String mediaType = 'movie',
  String? itemKind,
  int? season,
}) =>
    DownloadedMedia(
      id: 'r',
      mediaId: '42',
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
  test('home keeps its offline player route', () {
    expect(downloadedPlayLocation(_m()),
        '/player/movie/42?fileId=offline&title=Quill%20Harbor');
    expect(
      downloadedPlayLocation(_m(mediaType: 'episode', season: 2)),
      '/player/episode/42?fileId=offline&title=Quill%20Harbor'
      '&showId=s1&seasonNumber=2',
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
}
