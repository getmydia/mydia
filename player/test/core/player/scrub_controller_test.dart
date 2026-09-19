import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/player/scrub_controller.dart';

void main() {
  late Duration position;
  late Duration runtime;
  late List<Duration> commits;

  setUp(() {
    position = const Duration(minutes: 10);
    runtime = const Duration(hours: 2);
    commits = [];
  });

  ScrubController build(FakeAsync async) => ScrubController(
        position: () => position,
        duration: () => runtime,
        onCommit: (target) async => commits.add(target),
        elapsed: () => async.elapsed,
      );

  /// Presses [direction], then repeats it every [every] for [total], the way
  /// Android delivers a held D-pad key.
  void hold(
    ScrubController scrub,
    FakeAsync async,
    ScrubDirection direction, {
    required Duration total,
    Duration every = const Duration(milliseconds: 100),
  }) {
    scrub.step(direction, isRepeat: false);
    var held = Duration.zero;
    while (held < total) {
      async.elapse(every);
      held += every;
      scrub.step(direction, isRepeat: true);
    }
  }

  group('starting and stepping', () {
    test('a press starts a scrub one step from the playing position', () {
      fakeAsync((async) {
        final scrub = build(async);

        expect(scrub.step(ScrubDirection.forward, isRepeat: false), isTrue);

        expect(scrub.active, isTrue);
        expect(scrub.origin, const Duration(minutes: 10));
        expect(scrub.cursor, const Duration(minutes: 10, seconds: 10));
        scrub.dispose();
      });
    });

    test('presses accumulate without seeking', () {
      fakeAsync((async) {
        final scrub = build(async);

        scrub.step(ScrubDirection.backward, isRepeat: false);
        scrub.step(ScrubDirection.backward, isRepeat: false);
        scrub.step(ScrubDirection.backward, isRepeat: false);

        expect(scrub.cursor, const Duration(minutes: 9, seconds: 30));
        expect(commits, isEmpty);
        scrub.dispose();
      });
    });

    test('refuses to start when the runtime is unknown', () {
      fakeAsync((async) {
        runtime = Duration.zero;
        final scrub = build(async);

        expect(scrub.step(ScrubDirection.forward, isRepeat: false), isFalse);
        expect(scrub.active, isFalse);
        expect(scrub.displayFraction, isNull);
        scrub.dispose();
      });
    });

    test('clamps at zero', () {
      fakeAsync((async) {
        position = const Duration(seconds: 4);
        final scrub = build(async);

        scrub.step(ScrubDirection.backward, isRepeat: false);

        expect(scrub.cursor, Duration.zero);
        scrub.dispose();
      });
    });

    test('clamps at the runtime', () {
      fakeAsync((async) {
        position = const Duration(hours: 1, minutes: 59, seconds: 55);
        final scrub = build(async);

        scrub.step(ScrubDirection.forward, isRepeat: false);

        expect(scrub.cursor, runtime);
        scrub.dispose();
      });
    });

    test('displayFraction is the cursor over the runtime', () {
      fakeAsync((async) {
        position = const Duration(minutes: 59, seconds: 50);
        final scrub = build(async);

        scrub.step(ScrubDirection.forward, isRepeat: false);

        expect(scrub.displayFraction, 0.5);
        scrub.dispose();
      });
    });

    test('a repeat with no scrub active counts as a press', () {
      fakeAsync((async) {
        final scrub = build(async);

        scrub.step(ScrubDirection.forward, isRepeat: true);

        expect(scrub.cursor, const Duration(minutes: 10, seconds: 10));
        scrub.dispose();
      });
    });
  });

  group('holding a key', () {
    test('moves 30 seconds of media per second for the first 1.5 s', () {
      fakeAsync((async) {
        final scrub = build(async);

        hold(scrub, async, ScrubDirection.forward,
            total: const Duration(seconds: 1));

        // 10 s for the press, then 1 s held at 30x.
        expect(scrub.cursor, const Duration(minutes: 10, seconds: 40));
        scrub.dispose();
      });
    });

    test('speeds up to 2 minutes per second between 1.5 and 3 s', () {
      fakeAsync((async) {
        final scrub = build(async);

        hold(scrub, async, ScrubDirection.forward,
            total: const Duration(seconds: 2));

        // Press: 10 s. Repeats at 100..1400 ms: 14 x 3 s = 42 s.
        // Repeats at 1500..2000 ms: 6 x 12 s = 72 s. Total 124 s.
        expect(scrub.cursor, const Duration(minutes: 12, seconds: 4));
        scrub.dispose();
      });
    });

    test('tier boundaries', () {
      const twoHours = Duration(hours: 2);
      expect(
        ScrubController.speedFor(const Duration(milliseconds: 1499), twoHours),
        ScrubController.slowSpeed,
      );
      expect(
        ScrubController.speedFor(const Duration(milliseconds: 1500), twoHours),
        ScrubController.mediumSpeed,
      );
      expect(
        ScrubController.speedFor(const Duration(milliseconds: 2999), twoHours),
        ScrubController.mediumSpeed,
      );
      // A tenth of two hours per second: 720 s per s.
      expect(
        ScrubController.speedFor(const Duration(seconds: 3), twoHours),
        720,
      );
    });

    test('the fast tier never drops below the medium one', () {
      expect(
        ScrubController.speedFor(
            const Duration(seconds: 4), const Duration(minutes: 10)),
        ScrubController.mediumSpeed,
      );
    });
  });

  group('committing', () {
    test('commits by itself 1.5 s after the last step', () {
      fakeAsync((async) {
        final scrub = build(async);
        scrub.step(ScrubDirection.forward, isRepeat: false);

        async.elapse(const Duration(milliseconds: 1499));
        expect(commits, isEmpty);

        async.elapse(const Duration(milliseconds: 1));
        expect(commits, [const Duration(minutes: 10, seconds: 10)]);
        expect(scrub.active, isFalse);
        scrub.dispose();
      });
    });

    test('each step restarts the idle clock', () {
      fakeAsync((async) {
        final scrub = build(async);
        scrub.step(ScrubDirection.forward, isRepeat: false);
        async.elapse(const Duration(seconds: 1));
        scrub.step(ScrubDirection.forward, isRepeat: false);
        async.elapse(const Duration(seconds: 1));
        expect(commits, isEmpty);

        async.elapse(const Duration(milliseconds: 500));
        expect(commits, [const Duration(minutes: 10, seconds: 20)]);
        scrub.dispose();
      });
    });

    test('commit seeks once to the cursor and ends the scrub', () {
      fakeAsync((async) {
        final scrub = build(async);
        scrub.step(ScrubDirection.forward, isRepeat: false);

        scrub.commit();
        async.flushMicrotasks();

        expect(commits, [const Duration(minutes: 10, seconds: 10)]);
        expect(scrub.active, isFalse);
        expect(scrub.origin, isNull);
        scrub.dispose();
      });
    });

    test('commit with no scrub active does nothing', () {
      fakeAsync((async) {
        final scrub = build(async);

        scrub.commit();
        async.flushMicrotasks();

        expect(commits, isEmpty);
        scrub.dispose();
      });
    });

    test('cancel ends the scrub without seeking', () {
      fakeAsync((async) {
        final scrub = build(async);
        scrub.step(ScrubDirection.forward, isRepeat: false);

        scrub.cancel();
        async.elapse(const Duration(seconds: 2));

        expect(scrub.active, isFalse);
        expect(scrub.displayPosition, isNull);
        expect(commits, isEmpty);
        scrub.dispose();
      });
    });
  });

  group('settling after a commit', () {
    test('holds the cursor at the target until playback arrives', () {
      fakeAsync((async) {
        final scrub = build(async);
        scrub.step(ScrubDirection.forward, isRepeat: false);
        scrub.commit();
        async.flushMicrotasks();

        expect(scrub.displayPosition, const Duration(minutes: 10, seconds: 10));
        async.elapse(ScrubController.settlePoll);
        expect(scrub.displayPosition, const Duration(minutes: 10, seconds: 10));

        position = const Duration(minutes: 10, seconds: 8);
        async.elapse(ScrubController.settlePoll);
        expect(scrub.displayPosition, isNull);
        scrub.dispose();
      });
    });

    test('gives up after 10 s', () {
      fakeAsync((async) {
        final scrub = build(async);
        scrub.step(ScrubDirection.forward, isRepeat: false);
        scrub.commit();
        async.flushMicrotasks();

        async.elapse(ScrubController.settleTimeout);

        expect(scrub.displayPosition, isNull);
        scrub.dispose();
      });
    });

    test('a new scrub while settling continues from the target', () {
      fakeAsync((async) {
        final scrub = build(async);
        scrub.step(ScrubDirection.forward, isRepeat: false);
        scrub.commit();
        async.flushMicrotasks();

        scrub.step(ScrubDirection.forward, isRepeat: false);

        expect(scrub.origin, const Duration(minutes: 10, seconds: 10));
        expect(scrub.cursor, const Duration(minutes: 10, seconds: 20));
        scrub.dispose();
      });
    });

    test('cancel leaves a settling target alone', () {
      fakeAsync((async) {
        final scrub = build(async);
        scrub.step(ScrubDirection.forward, isRepeat: false);
        scrub.commit();
        async.flushMicrotasks();

        scrub.cancel();

        expect(scrub.displayPosition, const Duration(minutes: 10, seconds: 10));
        scrub.dispose();
      });
    });

    test('reset clears a settling target', () {
      fakeAsync((async) {
        final scrub = build(async);
        scrub.step(ScrubDirection.forward, isRepeat: false);
        scrub.commit();
        async.flushMicrotasks();

        scrub.reset();

        expect(scrub.displayPosition, isNull);
        scrub.dispose();
      });
    });
  });

  test('notifies on step, commit, cancel and settle', () {
    fakeAsync((async) {
      final scrub = build(async);
      var notifications = 0;
      scrub.addListener(() => notifications++);

      scrub.step(ScrubDirection.forward, isRepeat: false);
      expect(notifications, 1);
      scrub.cancel();
      expect(notifications, 2);
      scrub.step(ScrubDirection.forward, isRepeat: false);
      scrub.commit();
      async.flushMicrotasks();
      expect(notifications, 4);
      async.elapse(ScrubController.settleTimeout);
      expect(notifications, 5);
      scrub.dispose();
    });
  });
}
