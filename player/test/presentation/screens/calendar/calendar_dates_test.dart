import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/screens/calendar/calendar_dates.dart';

void main() {
  group('isoDate', () {
    test('zero-pads single-digit month and day', () {
      expect(isoDate(DateTime(2026, 1, 4)), '2026-01-04');
    });

    test('leaves double-digit month and day alone', () {
      expect(isoDate(DateTime(2026, 11, 25)), '2026-11-25');
    });

    test('ignores the time component', () {
      expect(isoDate(DateTime(2026, 8, 27, 23, 59, 59)), '2026-08-27');
    });
  });

  group('truncateToDay', () {
    test('drops the time component', () {
      expect(
          truncateToDay(DateTime(2026, 8, 27, 14, 30)), DateTime(2026, 8, 27));
    });

    test('is a no-op on a value that already has no time component', () {
      final day = DateTime(2026, 8, 27);
      expect(truncateToDay(day), day);
    });
  });

  group('isSameDay', () {
    test('true for the same day at different times', () {
      expect(
        isSameDay(DateTime(2026, 8, 27, 1), DateTime(2026, 8, 27, 23)),
        isTrue,
      );
    });

    test('false for a different day', () {
      expect(isSameDay(DateTime(2026, 8, 27), DateTime(2026, 8, 28)), isFalse);
    });

    test('false for the same month/day in a different year', () {
      expect(isSameDay(DateTime(2026, 8, 27), DateTime(2027, 8, 27)), isFalse);
    });
  });
}
