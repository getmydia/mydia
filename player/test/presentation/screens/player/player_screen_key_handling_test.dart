// Guards the previous/next-episode keyboard shortcuts directly, without
// standing up the full `PlayerScreen` — it's a `ConsumerStatefulWidget` that
// creates a real media_kit `Player` plus Riverpod/GraphQL providers, and
// there is no existing test harness for any of that (no
// `player_screen_test.dart` exists, and its other keyboard shortcuts —
// space, arrows, F, M, escape — are equally untested today). `PageUp`/
// `PageDown` is the one case simple enough to extract into a pure function
// (`handleEpisodeNavKey`, `@visibleForTesting` in `player_screen.dart`) that
// takes plain booleans and callbacks instead of closing over `State` fields,
// so it can be tested directly with a synthetic `KeyEvent`.

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show KeyEventResult;
import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/screens/player/player_screen.dart';

KeyDownEvent _keyDown(LogicalKeyboardKey key) => KeyDownEvent(
      physicalKey: PhysicalKeyboardKey.pageUp,
      logicalKey: key,
      timeStamp: Duration.zero,
    );

void main() {
  group('handleEpisodeNavKey', () {
    test('PageUp calls onPreviousEpisode when a previous episode exists', () {
      var previousCalls = 0;
      final result = handleEpisodeNavKey(
        _keyDown(LogicalKeyboardKey.pageUp),
        hasPreviousEpisode: true,
        hasNextEpisode: false,
        onPreviousEpisode: () => previousCalls++,
        onNextEpisode: () => fail('onNextEpisode should not fire for PageUp'),
      );

      expect(result, KeyEventResult.handled);
      expect(previousCalls, 1);
    });

    test(
        'PageUp does nothing (but is still handled) when there is no '
        'previous episode — matches the in-bar button\'s own disabled state',
        () {
      final result = handleEpisodeNavKey(
        _keyDown(LogicalKeyboardKey.pageUp),
        hasPreviousEpisode: false,
        hasNextEpisode: true,
        onPreviousEpisode: () =>
            fail('onPreviousEpisode should not fire when there is none'),
        onNextEpisode: () => fail('onNextEpisode should not fire for PageUp'),
      );

      expect(result, KeyEventResult.handled);
    });

    test('PageDown calls onNextEpisode when a next episode exists', () {
      var nextCalls = 0;
      final result = handleEpisodeNavKey(
        _keyDown(LogicalKeyboardKey.pageDown),
        hasPreviousEpisode: false,
        hasNextEpisode: true,
        onPreviousEpisode: () =>
            fail('onPreviousEpisode should not fire for PageDown'),
        onNextEpisode: () => nextCalls++,
      );

      expect(result, KeyEventResult.handled);
      expect(nextCalls, 1);
    });

    test(
        'PageDown does nothing (but is still handled) when there is no '
        'next episode', () {
      final result = handleEpisodeNavKey(
        _keyDown(LogicalKeyboardKey.pageDown),
        hasPreviousEpisode: true,
        hasNextEpisode: false,
        onPreviousEpisode: () =>
            fail('onPreviousEpisode should not fire for PageDown'),
        onNextEpisode: () =>
            fail('onNextEpisode should not fire when there is none'),
      );

      expect(result, KeyEventResult.handled);
    });

    test('ignores unrelated keys', () {
      final result = handleEpisodeNavKey(
        _keyDown(LogicalKeyboardKey.space),
        hasPreviousEpisode: true,
        hasNextEpisode: true,
        onPreviousEpisode: () => fail('should not fire for an unrelated key'),
        onNextEpisode: () => fail('should not fire for an unrelated key'),
      );

      expect(result, KeyEventResult.ignored);
    });

    test('ignores key-up events (only KeyDownEvent triggers navigation)', () {
      const keyUp = KeyUpEvent(
        physicalKey: PhysicalKeyboardKey.pageUp,
        logicalKey: LogicalKeyboardKey.pageUp,
        timeStamp: Duration.zero,
      );

      final result = handleEpisodeNavKey(
        keyUp,
        hasPreviousEpisode: true,
        hasNextEpisode: true,
        onPreviousEpisode: () => fail('should not fire on key-up'),
        onNextEpisode: () => fail('should not fire on key-up'),
      );

      expect(result, KeyEventResult.ignored);
    });
  });
}
