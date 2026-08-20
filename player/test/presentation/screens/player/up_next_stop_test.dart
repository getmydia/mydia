import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/widgets/video_controls/up_next_countdown.dart';

void main() {
  group('stop paths', () {
    test('cancel from Escape stops a countdown mid-drain', () {
      fakeAsync((async) {
        var fired = 0;
        final countdown = UpNextCountdown(onElapsed: () => fired++);
        countdown.start();
        async.elapse(const Duration(seconds: 4));

        // What `_handleKeyEvent`'s escape branch calls.
        countdown.cancel();
        async.elapse(const Duration(seconds: 60));

        expect(fired, 0);
        countdown.dispose();
      });
    });

    test('a backward seek stops it', () {
      fakeAsync((async) {
        var fired = 0;
        final countdown = UpNextCountdown(onElapsed: () => fired++);
        countdown.start();
        async.elapse(const Duration(seconds: 4));

        // What `seekToReal` calls when the target is behind the position.
        countdown.cancel();
        async.elapse(const Duration(seconds: 60));

        expect(fired, 0);
        countdown.dispose();
      });
    });

    test('pausing playback holds it, resuming releases it', () {
      fakeAsync((async) {
        var fired = 0;
        final countdown = UpNextCountdown(onElapsed: () => fired++);
        countdown.start();

        async.elapse(const Duration(seconds: 2));
        countdown.hold(UpNextHold.paused);
        async.elapse(const Duration(minutes: 5));
        expect(fired, 0, reason: 'paused playback must not auto-advance');

        countdown.release(UpNextHold.paused);
        async.elapse(const Duration(seconds: 10));
        expect(fired, 1);
        countdown.dispose();
      });
    });

    test('engagement and pause hold independently', () {
      fakeAsync((async) {
        var fired = 0;
        final countdown = UpNextCountdown(onElapsed: () => fired++);
        countdown.start();

        countdown.hold(UpNextHold.paused);
        countdown.hold(UpNextHold.engaged);
        // Playback resumes while the pointer is still on the prompt.
        countdown.release(UpNextHold.paused);
        async.elapse(const Duration(minutes: 5));
        expect(fired, 0);

        countdown.release(UpNextHold.engaged);
        async.elapse(const Duration(seconds: 10));
        expect(fired, 1);
        countdown.dispose();
      });
    });
  });
}
