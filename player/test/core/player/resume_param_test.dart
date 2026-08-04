import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/player/resume_plan.dart';

void main() {
  group('shouldPassResume', () {
    test('passes for a continue state well into an unwatched episode', () {
      expect(
        shouldPassResume(
          isContinueState: true,
          positionSeconds: 600,
          watched: false,
        ),
        isTrue,
      );
    });

    test('declines when the state is not continue', () {
      expect(
        shouldPassResume(
          isContinueState: false,
          positionSeconds: 600,
          watched: false,
        ),
        isFalse,
      );
    });

    test('declines inside the first 30 seconds', () {
      expect(
        shouldPassResume(
          isContinueState: true,
          positionSeconds: 30,
          watched: false,
        ),
        isFalse,
      );
    });

    test('declines when the item is already watched', () {
      expect(
        shouldPassResume(
          isContinueState: true,
          positionSeconds: 600,
          watched: true,
        ),
        isFalse,
      );
    });

    test('declines when there is no recorded position', () {
      expect(
        shouldPassResume(
          isContinueState: true,
          positionSeconds: null,
          watched: false,
        ),
        isFalse,
      );
    });
  });
}
