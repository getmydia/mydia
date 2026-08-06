import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/models/show_detail.dart';

void main() {
  group('ShowDetail.fromJson new hero fields', () {
    Map<String, dynamic> baseJson() => {
          'id': 'sh-1',
          'title': 'Harbor Lights',
          'monitored': true,
          'seasonCount': 2,
          'episodeCount': 12,
          'artwork': null,
          'isFavorite': false,
        };

    test('parses cast, trailerUrl, and similar', () {
      final json = {
        ...baseJson(),
        'cast': [
          {'name': 'Del Osei', 'character': 'Det. Osei', 'profileUrl': null},
        ],
        'trailerUrl': 'https://www.youtube.com/watch?v=xyz789',
        'similar': [
          {
            'id': 's-2',
            'type': 'tv_show',
            'title': 'Salt Line',
            'year': 2020,
            'artwork': null,
            'addedAt': null,
          },
        ],
      };

      final show = ShowDetail.fromJson(json);

      expect(show.cast, hasLength(1));
      expect(show.cast.first.name, 'Del Osei');
      expect(show.trailerUrl, 'https://www.youtube.com/watch?v=xyz789');
      expect(show.similar, hasLength(1));
      expect(show.similar.first.title, 'Salt Line');
    });

    test('defaults to empty/null when absent', () {
      final show = ShowDetail.fromJson(baseJson());

      expect(show.cast, isEmpty);
      expect(show.trailerUrl, isNull);
      expect(show.similar, isEmpty);
    });
  });
}
