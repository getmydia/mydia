// Guards the auto-vs-manual next-episode split after Up Next is dismissed,
// without standing up `PlayerScreen`. Mounting the screen needs a live
// media_kit Player plus Riverpod/GraphQL (see
// `player_screen_key_handling_test.dart`); the load-bearing wiring is the
// countdown callback and `_playNextEpisode`'s cancel flag, which this
// reconstructs with the same helpers the screen uses.

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/screens/player/player_screen.dart';
import 'package:player/presentation/widgets/video_controls/up_next_countdown.dart';
import 'package:player/presentation/widgets/video_controls/up_next_policy.dart';

void main() {
  group('bindUpNextCountdownElapsed', () {
    test('marks the fire as from the auto countdown', () {
      bool? fromAuto;
      bindUpNextCountdownElapsed(({bool fromAutoCountdown = false}) {
        fromAuto = fromAutoCountdown;
      })();
      expect(fromAuto, isTrue);
    });
  });

  group('next episode after dismissing up-next', () {
    test(
        'a cancelled countdown does not navigate; a later manual next still '
        'does', () {
      fakeAsync((async) {
        var autoPlayCancelled = false;
        var navigated = 0;

        void playNext({bool fromAutoCountdown = false}) {
          if (shouldBlockAutoPlayNext(
            autoPlayCancelled: autoPlayCancelled,
            fromAutoCountdown: fromAutoCountdown,
          )) {
            return;
          }
          navigated++;
        }

        final countdown = UpNextCountdown(
          onElapsed: bindUpNextCountdownElapsed(playNext),
        );
        countdown.start();
        async.elapse(const Duration(seconds: 4));

        // What `_cancelAutoPlay` does: stop the clock, then set the flag.
        countdown.cancel();
        autoPlayCancelled = true;
        async.elapse(const Duration(seconds: 60));
        expect(navigated, 0, reason: 'dismissed auto-play must not navigate');

        // Transport / keyboard / remote: `_playNextEpisode()` default.
        playNext();
        expect(navigated, 1, reason: 'manual next must still navigate');

        countdown.dispose();
      });
    });
  });
}
