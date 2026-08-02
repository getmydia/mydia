// `resolveResumePlan` is the single place every playback path asks about
// resuming. Before it existed, the decision lived inside individual branches
// of `_initializePlayer`, and three cast exits plus the offline branch
// skipped it entirely (see the 2026-08-02 cast-and-offline-resume spec).

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/player/resume_plan.dart';

void main() {
  Future<bool?> never(int saved, int total) async {
    fail('ask() must not be called when the plan is decided without the user');
  }

  group('resolveResumePlan', () {
    test('offers, and honors an accepted resume', () async {
      var askedSaved = 0;
      var askedTotal = 0;

      final plan = await resolveResumePlan(
        savedPositionSeconds: 2700,
        realDuration: const Duration(seconds: 5400),
        resumeOverride: null,
        mounted: true,
        ask: (saved, total) async {
          askedSaved = saved;
          askedTotal = total;
          return true;
        },
      );

      expect(plan, isNotNull);
      expect(plan!.position, const Duration(seconds: 2700));
      expect(plan.resumes, isTrue);
      expect(askedSaved, 2700);
      expect(askedTotal, 5400);
    });

    test('starts over when the user declines', () async {
      final plan = await resolveResumePlan(
        savedPositionSeconds: 2700,
        realDuration: const Duration(seconds: 5400),
        resumeOverride: null,
        mounted: true,
        ask: (_, __) async => false,
      );

      expect(plan, isNotNull);
      expect(plan!.position, Duration.zero);
      expect(plan.resumes, isFalse);
    });

    test('does not ask below the minimum threshold', () async {
      final plan = await resolveResumePlan(
        savedPositionSeconds: kMinResumeThresholdSeconds,
        realDuration: const Duration(seconds: 5400),
        resumeOverride: null,
        mounted: true,
        ask: never,
      );

      expect(plan!.position, Duration.zero);
    });

    test('does not ask without a real duration', () async {
      final plan = await resolveResumePlan(
        savedPositionSeconds: 2700,
        realDuration: null,
        resumeOverride: null,
        mounted: true,
        ask: never,
      );

      expect(plan!.position, Duration.zero);
    });

    test('an override of zero suppresses the dialog and starts at zero',
        () async {
      // A seek-driven restart targeting real position 0 sets the override to
      // exactly 0, which must not be confused with "no override was set".
      // Confusing them lets the dialog prompt about a stale saved position
      // and silently overwrite the user's explicit seek to the start.
      final plan = await resolveResumePlan(
        savedPositionSeconds: 2700,
        realDuration: const Duration(seconds: 5400),
        resumeOverride: 0,
        mounted: true,
        ask: never,
      );

      expect(plan!.position, Duration.zero);
    });

    test('a non-zero override is used verbatim, without asking', () async {
      final plan = await resolveResumePlan(
        savedPositionSeconds: 2700,
        realDuration: const Duration(seconds: 5400),
        resumeOverride: 1800,
        mounted: true,
        ask: never,
      );

      expect(plan!.position, const Duration(seconds: 1800));
    });

    test('returns null when the caller is already unmounted', () async {
      final plan = await resolveResumePlan(
        savedPositionSeconds: 2700,
        realDuration: const Duration(seconds: 5400),
        resumeOverride: null,
        mounted: false,
        ask: never,
      );

      expect(plan, isNull);
    });

    test('returns null when the dialog is dismissed by teardown', () async {
      // `showDialog` completes with null when the route is popped without an
      // answer. Callers must abandon: `dispose()` has already run, and going
      // on would start a session and build a Player for a dead screen.
      final plan = await resolveResumePlan(
        savedPositionSeconds: 2700,
        realDuration: const Duration(seconds: 5400),
        resumeOverride: null,
        mounted: true,
        ask: (_, __) async => null,
      );

      expect(plan, isNull);
    });
  });
}
