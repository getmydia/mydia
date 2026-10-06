import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/sources/source_error.dart';
import 'package:player/presentation/screens/calendar/calendar_screen.dart';

void main() {
  group('isCalendarUnsupported', () {
    test('recognises a source that reports the calendar as unsupported', () {
      expect(
        isCalendarUnsupported(const SourceException.unsupported()),
        isTrue,
      );
    });

    test('does not claim an auth failure is a version problem', () {
      expect(
        isCalendarUnsupported(const SourceException.unauthorized()),
        isFalse,
      );
    });

    test('does not claim a transport failure is a version problem', () {
      expect(
        isCalendarUnsupported(const SourceException.unreachable()),
        isFalse,
      );
    });

    test('does not claim an unrelated error is a version problem', () {
      expect(isCalendarUnsupported(StateError('boom')), isFalse);
    });
  });
}
