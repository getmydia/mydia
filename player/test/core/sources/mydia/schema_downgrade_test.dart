import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/mydia/schema_downgrade.dart';
import 'package:player/domain/sources/source_error.dart';

void main() {
  group('isUnknownFieldError', () {
    test('detects an unknown field error in SourceException', () {
      const error = SourceException.server(
        'Cannot query field "newEpisodeCount" on type "RecentlyAddedItem".',
      );
      expect(isUnknownFieldError(error), isTrue);
    });

    test('ignores ordinary SourceException errors', () {
      const error = SourceException.server('Not authenticated');
      expect(isUnknownFieldError(error), isFalse);
    });

    test('detects an unknown field error in plain Exception or string', () {
      final error = Exception('Cannot query field "foo"');
      expect(isUnknownFieldError(error), isTrue);
    });

    test('an unknown argument is an unknown-field error', () {
      expect(
        isUnknownFieldError(const SourceException.server(
            'Unknown argument "maxHeight" on field "startStreamingSession".')),
        isTrue,
      );
    });

    test('ignores a SourceException with null message', () {
      const error = SourceException.unreachable();
      expect(isUnknownFieldError(error), isFalse);
    });
  });
}
