import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/screens/calendar/calendar_screen.dart';

void main() {
  group('indexOfToday', () {
    test('finds the group for today when today has entries', () {
      final index = indexOfToday(
        [DateTime(2026, 8, 20), DateTime(2026, 8, 27), DateTime(2026, 8, 30)],
        DateTime(2026, 8, 27),
      );

      expect(index, 1);
    });

    test('falls forward to the next day when today has no entries', () {
      final index = indexOfToday(
        [DateTime(2026, 8, 20), DateTime(2026, 8, 30)],
        DateTime(2026, 8, 27),
      );

      expect(index, 1);
    });

    test('is null when every day is in the past', () {
      final index = indexOfToday(
        [DateTime(2026, 8, 20), DateTime(2026, 8, 21)],
        DateTime(2026, 8, 27),
      );

      expect(index, isNull);
    });

    test('ignores the time of day on the reference date', () {
      final index = indexOfToday(
        [DateTime(2026, 8, 27)],
        DateTime(2026, 8, 27, 23, 30),
      );

      expect(index, 0);
    });

    test('is null for an empty list', () {
      expect(indexOfToday(const [], DateTime(2026, 8, 27)), isNull);
    });
  });
}
