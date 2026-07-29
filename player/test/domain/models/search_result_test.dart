import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/models/search_result.dart';

void main() {
  group('SearchResultType', () {
    test('parses all four API values', () {
      expect(SearchResultType.fromString('MOVIE'), SearchResultType.movie);
      expect(SearchResultType.fromString('TV_SHOW'), SearchResultType.tvShow);
      expect(SearchResultType.fromString('EPISODE'), SearchResultType.episode);
      expect(
        SearchResultType.fromString('COLLECTION'),
        SearchResultType.collection,
      );
    });

    test('round-trips through apiValue', () {
      for (final type in SearchResultType.values) {
        expect(SearchResultType.fromString(type.apiValue), type);
      }
    });

    test('round-trips through queryValue', () {
      for (final type in SearchResultType.values) {
        expect(SearchResultType.fromQueryValue(type.queryValue), type);
      }
    });

    test('fromQueryValue returns null for unknown or missing values', () {
      expect(SearchResultType.fromQueryValue(null), isNull);
      expect(SearchResultType.fromQueryValue('nonsense'), isNull);
    });

    test('exposes section titles', () {
      expect(SearchResultType.movie.sectionTitle, 'Movies');
      expect(SearchResultType.tvShow.sectionTitle, 'TV Shows');
      expect(SearchResultType.episode.sectionTitle, 'Episodes');
      expect(SearchResultType.collection.sectionTitle, 'Collections');
    });
  });

  group('SearchResult.routePath', () {
    test('routes each type to its detail screen', () {
      expect(_result(SearchResultType.movie).routePath, '/movie/abc');
      expect(_result(SearchResultType.tvShow).routePath, '/show/abc');
      expect(_result(SearchResultType.episode).routePath, '/episode/abc');
      expect(_result(SearchResultType.collection).routePath, '/collection/abc');
    });
  });

  group('SearchResult.fromJson', () {
    test('reads nested artwork URLs', () {
      final result = SearchResult.fromJson(const {
        'id': 'abc',
        'type': 'MOVIE',
        'title': 'Alien',
        'year': 1979,
        'score': 100.0,
        'artwork': {
          'posterUrl': 'https://example.test/poster.jpg',
          'backdropUrl': 'https://example.test/backdrop.jpg',
          'thumbnailUrl': null,
        },
      });

      expect(result.posterUrl, 'https://example.test/poster.jpg');
      expect(result.backdropUrl, 'https://example.test/backdrop.jpg');
      expect(result.thumbnailUrl, isNull);
      expect(result.score, 100.0);
    });

    test('tolerates a null artwork object', () {
      final result = SearchResult.fromJson(const {
        'id': 'abc',
        'type': 'MOVIE',
        'title': 'Alien',
        'artwork': null,
      });

      expect(result.posterUrl, isNull);
      expect(result.yearDisplay, '');
    });

    test('reads episode context and formats an episode code', () {
      final result = SearchResult.fromJson(const {
        'id': 'ep-1',
        'type': 'EPISODE',
        'title': 'Fountain of Youth',
        'subtitle': 'Alien Nation',
        'seasonNumber': 1,
        'episodeNumber': 3,
        'parentId': 'show-1',
      });

      expect(result.subtitle, 'Alien Nation');
      expect(result.seasonNumber, 1);
      expect(result.episodeNumber, 3);
      expect(result.parentId, 'show-1');
      expect(result.episodeCode, 'S01E03');
    });

    test('episodeCode is null when the numbers are missing', () {
      expect(_result(SearchResultType.movie).episodeCode, isNull);
    });
  });

  group('SearchResults.fromJson', () {
    test('parses sections and totals', () {
      final results = SearchResults.fromJson(const {
        'totalCount': 3,
        'sections': [
          {
            'type': 'MOVIE',
            'totalCount': 2,
            'results': [
              {'id': 'm1', 'type': 'MOVIE', 'title': 'Alien'},
            ],
          },
          {
            'type': 'EPISODE',
            'totalCount': 1,
            'results': [
              {'id': 'e1', 'type': 'EPISODE', 'title': 'Alien Encounter'},
            ],
          },
        ],
      });

      expect(results.totalCount, 3);
      expect(results.sections.map((s) => s.type).toList(), [
        SearchResultType.movie,
        SearchResultType.episode,
      ]);
      expect(results.sections.first.totalCount, 2);
      expect(results.sections.first.results.single.title, 'Alien');
      expect(results.isEmpty, isFalse);
    });

    test('empty is empty', () {
      expect(SearchResults.empty.sections, isEmpty);
      expect(SearchResults.empty.isEmpty, isTrue);
    });
  });
}

SearchResult _result(SearchResultType type) =>
    SearchResult(id: 'abc', type: type, title: 'Alien');
