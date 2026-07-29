import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/graphql/watch/resume_gate.dart';

void main() {
  final base = DateTime(2026, 7, 28, 12, 0);
  const threshold = ResumeGate.defaultMinimumBackground;

  test('a long background triggers a refresh', () {
    final gate = ResumeGate()..onPaused(base);

    expect(gate.onResumed(base.add(const Duration(minutes: 5))), isTrue);
  });

  test('a brief background does not', () {
    final gate = ResumeGate()..onPaused(base);

    expect(gate.onResumed(base.add(const Duration(seconds: 5))), isFalse);
  });

  test('exactly the threshold triggers a refresh', () {
    final gate = ResumeGate()..onPaused(base);

    expect(gate.onResumed(base.add(threshold)), isTrue);
  });

  test('a resume with no preceding pause does nothing', () {
    // Notification shades and permission dialogs produce inactive/resumed
    // without a pause; those must not refetch the library.
    expect(ResumeGate().onResumed(base), isFalse);
  });

  test('the pause is consumed, so a second resume does not re-trigger', () {
    final gate = ResumeGate()..onPaused(base);

    expect(gate.onResumed(base.add(const Duration(minutes: 5))), isTrue);
    expect(gate.onResumed(base.add(const Duration(minutes: 6))), isFalse);
  });

  group('applyAppLifecycleState', () {
    // This is the wiring `_MyAppState.didChangeAppLifecycleState` delegates
    // to. It is pinned directly, without a widget tree or the real
    // OS-driven lifecycle, so a typo folding `inactive` into the
    // paused/hidden case — which would turn every notification shade into a
    // refetch — fails a fast unit test instead of shipping green.

    test('inactive is not a pause: a later resume does not trigger', () {
      final gate = ResumeGate();

      final duringInactive =
          applyAppLifecycleState(gate, AppLifecycleState.inactive, base);
      final onResume = applyAppLifecycleState(
        gate,
        AppLifecycleState.resumed,
        base.add(const Duration(hours: 1)),
      );

      expect(duringInactive, isFalse);
      expect(onResume, isFalse);
    });

    test('detached is not a pause either', () {
      final gate = ResumeGate();

      applyAppLifecycleState(gate, AppLifecycleState.detached, base);
      final onResume = applyAppLifecycleState(
        gate,
        AppLifecycleState.resumed,
        base.add(const Duration(hours: 1)),
      );

      expect(onResume, isFalse);
    });

    test('paused then resumed past the threshold triggers a refresh', () {
      final gate = ResumeGate();

      final duringPause =
          applyAppLifecycleState(gate, AppLifecycleState.paused, base);
      final onResume = applyAppLifecycleState(
        gate,
        AppLifecycleState.resumed,
        base.add(threshold),
      );

      expect(duringPause, isFalse);
      expect(onResume, isTrue);
    });

    test('paused then resumed before the threshold does not trigger', () {
      final gate = ResumeGate();

      applyAppLifecycleState(gate, AppLifecycleState.paused, base);
      final onResume = applyAppLifecycleState(
        gate,
        AppLifecycleState.resumed,
        base.add(const Duration(seconds: 5)),
      );

      expect(onResume, isFalse);
    });

    test('hidden is treated the same as paused', () {
      final gate = ResumeGate();

      applyAppLifecycleState(gate, AppLifecycleState.hidden, base);
      final onResume = applyAppLifecycleState(
        gate,
        AppLifecycleState.resumed,
        base.add(threshold),
      );

      expect(onResume, isTrue);
    });
  });
}
