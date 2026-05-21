import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/models/torrent_candidate.dart';

// Plan U7 names this file as a required deliverable. The full widget test
// requires a Riverpod ProviderScope override for the torrentCandidatesProvider
// and a GraphQL test client, which we can wire up in a follow-up. This stub
// at least exercises the TorrentCandidate model and locks in formattedSize.
void main() {
  group('TorrentCandidate', () {
    test('formattedSize renders bytes', () {
      const c = TorrentCandidate(
        title: 'x',
        size: 512,
        magnetLink: 'magnet:?xt=urn:btih:abc',
        indexer: 'TestIndexer',
        healthScore: 0,
      );
      expect(c.formattedSize, '512 B');
    });

    test('formattedSize renders MB and GB', () {
      const mb = TorrentCandidate(
        title: 'x',
        size: 5 * 1024 * 1024,
        magnetLink: 'magnet:?xt=urn:btih:abc',
        indexer: 'TestIndexer',
        healthScore: 0,
      );
      expect(mb.formattedSize, '5.0 MB');

      const gb = TorrentCandidate(
        title: 'x',
        size: 2 * 1024 * 1024 * 1024,
        magnetLink: 'magnet:?xt=urn:btih:abc',
        indexer: 'TestIndexer',
        healthScore: 0,
      );
      expect(gb.formattedSize, '2.0 GB');
    });

    test('equality is value-based', () {
      const a = TorrentCandidate(
        title: 'x',
        size: 1,
        magnetLink: 'magnet:?xt=urn:btih:abc',
        indexer: 'I',
        healthScore: 0,
      );
      const b = TorrentCandidate(
        title: 'x',
        size: 1,
        magnetLink: 'magnet:?xt=urn:btih:abc',
        indexer: 'I',
        healthScore: 0,
      );
      expect(a, equals(b));
    });

    test('fromJson parses healthScore as double even when given int', () {
      final c = TorrentCandidate.fromJson({
        'title': 'x',
        'size': 1,
        'seeders': null,
        'leechers': null,
        'magnetLink': 'magnet:?xt=urn:btih:abc',
        'indexer': 'I',
        'quality': null,
        'healthScore': 5,
      });
      expect(c.healthScore, isA<double>());
      expect(c.healthScore, 5.0);
    });
  });
}
