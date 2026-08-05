import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/models/recently_added_item.dart';

void main() {
  Map<String, dynamic> json(Map<String, dynamic> overrides) => {
        'id': 'abc',
        'type': 'tv_show',
        'title': 'The Bear',
        ...overrides,
      };

  group('fromJson', () {
    test('parses the episode context fields', () {
      final item = RecentlyAddedItem.fromJson(json({
        'newEpisodeCount': 3,
        'latestSeasonNumber': 4,
        'latestEpisodeNumber': 2,
      }));

      expect(item.newEpisodeCount, 3);
      expect(item.latestSeasonNumber, 4);
      expect(item.latestEpisodeNumber, 2);
    });

    test('tolerates every context field being absent', () {
      final item = RecentlyAddedItem.fromJson(json({}));

      expect(item.newEpisodeCount, isNull);
      expect(item.latestSeasonNumber, isNull);
      expect(item.latestEpisodeNumber, isNull);
    });
  });

  group('newContentLabel', () {
    test('names the episode when there is exactly one with numbers', () {
      final item = RecentlyAddedItem.fromJson(json({
        'newEpisodeCount': 1,
        'latestSeasonNumber': 4,
        'latestEpisodeNumber': 2,
      }));

      expect(item.newContentLabel, 'S04E02');
    });

    test('pads a two-digit season without truncating it', () {
      final item = RecentlyAddedItem.fromJson(json({
        'newEpisodeCount': 1,
        'latestSeasonNumber': 12,
        'latestEpisodeNumber': 5,
      }));

      expect(item.newContentLabel, 'S12E05');
    });

    test('counts when there is one but no numbers', () {
      final item = RecentlyAddedItem.fromJson(json({'newEpisodeCount': 1}));

      expect(item.newContentLabel, '1 new episode');
    });

    test('pluralizes above one', () {
      final item = RecentlyAddedItem.fromJson(json({
        'newEpisodeCount': 3,
        'latestSeasonNumber': 4,
        'latestEpisodeNumber': 2,
      }));

      expect(item.newContentLabel, '3 new episodes');
    });

    test('is null when the count is absent', () {
      expect(RecentlyAddedItem.fromJson(json({})).newContentLabel, isNull);
    });

    test('is null when the count is zero', () {
      final item = RecentlyAddedItem.fromJson(json({'newEpisodeCount': 0}));

      expect(item.newContentLabel, isNull);
    });
  });
}
