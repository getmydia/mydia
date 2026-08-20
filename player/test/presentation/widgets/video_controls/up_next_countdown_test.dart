import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/widgets/video_controls/up_next_countdown.dart';

void main() {
  /// A clock the tests drive by hand, so `raceGuard` can be exercised without
  /// depending on the wall clock.
  DateTime now = DateTime(2026, 8, 19);

  setUp(() => now = DateTime(2026, 8, 19));

  UpNextCountdown build({
    required void Function() onElapsed,
    Duration total = const Duration(seconds: 10),
  }) =>
      UpNextCountdown(
        total: total,
        onElapsed: onElapsed,
        clock: () => now,
      );

  /// Advances both the fake timer queue and the fake clock together, so
  /// `raceGuard` sees the same passage of time the ticker does.
  void advance(FakeAsync async, Duration by) {
    now = now.add(by);
    async.elapse(by);
  }

  test('fraction starts at 1 and reaches 0 as it drains', () {
    fakeAsync((async) {
      final countdown = build(onElapsed: () {});
      countdown.start();
      expect(countdown.fraction, 1.0);

      advance(async, const Duration(seconds: 5));
      expect(countdown.fraction, closeTo(0.5, 0.001));

      advance(async, const Duration(seconds: 5));
      expect(countdown.fraction, 0.0);
      countdown.dispose();
    });
  });

  test('fires onElapsed exactly once', () {
    fakeAsync((async) {
      var fired = 0;
      final countdown = build(onElapsed: () => fired++);
      countdown.start();

      advance(async, const Duration(seconds: 30));
      expect(fired, 1);
      countdown.dispose();
    });
  });

  test('a hold stops the clock', () {
    fakeAsync((async) {
      var fired = 0;
      final countdown = build(onElapsed: () => fired++);
      countdown.start();

      advance(async, const Duration(seconds: 3));
      countdown.hold(UpNextHold.engaged);
      advance(async, const Duration(seconds: 60));

      expect(fired, 0);
      expect(countdown.remaining, const Duration(seconds: 7));
      countdown.dispose();
    });
  });

  test('holds compose: releasing one keeps it held while the other stands', () {
    fakeAsync((async) {
      var fired = 0;
      final countdown = build(onElapsed: () => fired++);
      countdown.start();

      countdown.hold(UpNextHold.engaged);
      countdown.hold(UpNextHold.paused);
      countdown.release(UpNextHold.engaged);
      advance(async, const Duration(seconds: 60));
      expect(fired, 0, reason: 'still held by UpNextHold.paused');

      countdown.release(UpNextHold.paused);
      advance(async, const Duration(seconds: 60));
      expect(fired, 1);
      countdown.dispose();
    });
  });

  test('the race guard defers a fire that lands right after an input', () {
    fakeAsync((async) {
      var fired = 0;
      final countdown = build(onElapsed: () => fired++);
      countdown.start();

      advance(async, const Duration(seconds: 9));
      // The viewer moves the pointer a beat before the countdown lands.
      countdown.noteInput();
      advance(async, const Duration(seconds: 1));

      expect(fired, 0, reason: 'inside the 1s race guard');
      expect(countdown.remaining, Duration.zero);

      advance(async, const Duration(seconds: 2));
      expect(fired, 1, reason: 'guard elapsed, so it may fire');
      countdown.dispose();
    });
  });

  test('cancel beats a fire that would otherwise happen', () {
    fakeAsync((async) {
      var fired = 0;
      final countdown = build(onElapsed: () => fired++);
      countdown.start();

      advance(async, const Duration(seconds: 9));
      countdown.cancel();
      advance(async, const Duration(seconds: 60));

      expect(fired, 0);
      countdown.dispose();
    });
  });

  test('notifies listeners on each tick and on hold changes', () {
    fakeAsync((async) {
      var notifications = 0;
      final countdown = build(onElapsed: () {})
        ..addListener(() => notifications++);
      countdown.start();

      advance(async, const Duration(seconds: 2));
      expect(notifications, 2);

      countdown.hold(UpNextHold.engaged);
      expect(notifications, 3);

      // A redundant hold is not a change and must not notify.
      countdown.hold(UpNextHold.engaged);
      expect(notifications, 3);
      countdown.dispose();
    });
  });
}
