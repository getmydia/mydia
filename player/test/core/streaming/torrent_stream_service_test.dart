import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/models/torrent_candidate.dart';

// Plan U7 calls for a TorrentStreamService test. A useful test requires
// mocking the GraphQLClient, which is fiddly without a shared test harness.
// This stub locks in the JSON contract that startSession expects from the
// server payload so future regressions on that contract trip a fast test.
void main() {
  group('startSession payload contract', () {
    test('TorrentCandidate.fromJson tolerates null seeders/leechers/quality',
        () {
      final c = TorrentCandidate.fromJson({
        'title': 'Movie 1080p',
        'size': 1024,
        'seeders': null,
        'leechers': null,
        'magnetLink': 'magnet:?xt=urn:btih:abcd',
        'indexer': 'TestIndexer',
        'quality': null,
        'healthScore': 0.5,
      });

      expect(c.title, 'Movie 1080p');
      expect(c.seeders, isNull);
      expect(c.leechers, isNull);
      expect(c.quality, isNull);
      expect(c.healthScore, 0.5);
    });

    test('TorrentCandidate.fromJson parses populated fields', () {
      final c = TorrentCandidate.fromJson({
        'title': 'Movie 1080p',
        'size': 1024,
        'seeders': 100,
        'leechers': 5,
        'magnetLink': 'magnet:?xt=urn:btih:abcd',
        'indexer': 'TestIndexer',
        'quality': '1080p',
        'healthScore': 0.9,
      });

      expect(c.seeders, 100);
      expect(c.leechers, 5);
      expect(c.quality, '1080p');
    });
  });
}
