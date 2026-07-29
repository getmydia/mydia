import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/graphql/watch/resume_gate.dart';

void main() {
  final base = DateTime(2026, 7, 28, 12, 0);

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

    expect(gate.onResumed(base.add(const Duration(seconds: 30))), isTrue);
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
}
