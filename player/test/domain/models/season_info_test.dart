import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/models/season_info.dart';

void main() {
  group('SeasonInfo.fromJson', () {
    test('parses a season watch status', () {
      final season = SeasonInfo.fromJson(const {
        'seasonNumber': 1,
        'episodeCount': 10,
        'airedEpisodeCount': 10,
        'hasFiles': true,
        'watchStatus': {
          'watched': false,
          'percentage': null,
          'unwatchedEpisodeCount': 4,
        },
      });

      expect(season.watchStatus!.unwatchedEpisodeCount, 4);
    });

    test('leaves watch status null when absent', () {
      final season = SeasonInfo.fromJson(const {
        'seasonNumber': 1,
        'episodeCount': 10,
        'airedEpisodeCount': 10,
        'hasFiles': true,
      });

      expect(season.watchStatus, isNull);
    });
  });
}
