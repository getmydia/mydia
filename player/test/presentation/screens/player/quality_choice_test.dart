// Unit coverage for `applyQualityChoice`, the decision behind the quality
// picker: put the chosen rung into effect, and if that fails, put the one
// that was already working back and try exactly once more.
//
// Extracted from `_showQualitySelector` and tested here rather than through
// the widget for the reason spelled out on the function itself: the chrome
// that owns the quality button is never built under `flutter test`, because
// `_waitForPlaylist` polls a real URL that `flutter_test`'s `HttpOverrides`
// answers with 400 every time, so the screen reaches its error state first.
// Same precedent as `shouldRestartForSeek`, pulled out of this file for the
// same reason.

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/playback/playback_plan.dart';
import 'package:player/domain/models/quality_rung.dart';
import 'package:player/core/playback/quality_choice.dart';

const _selected = QualityRung(label: '720p', height: 720, maxBitrateKbps: 4000);
const _previous = QualityRung.original;

/// One call to the `restart` callback.
class _RestartCall {
  _RestartCall(this.rung, this.isFallback);

  final QualityRung rung;
  final bool isFallback;

  @override
  String toString() => '${rung.label}(isFallback: $isFallback)';
}

/// Records every callback `applyQualityChoice` makes, and fails or abandons
/// whichever restarts [failing] or [abandoned] name.
class _Recorder {
  _Recorder({
    this.failing = const <int>{},
    this.abandoned = const <int>{},
    this.storageFails = false,
  });

  /// Zero-based indices of `restart` calls that throw.
  final Set<int> failing;

  /// Zero-based indices of `restart` calls that report `false`: another
  /// source switch took over before this one could apply.
  final Set<int> abandoned;

  /// Stands in for secure storage being unavailable — a locked or missing
  /// keyring on Linux desktop, which `flutter_secure_storage` needs.
  final bool storageFails;

  /// Stands in for the widget still being mounted. Set through a cascade at
  /// the call site rather than the constructor, since only one test cares.
  bool active = true;

  /// The rung each restart saw in memory when it ran. This is the property
  /// that matters: the viewer's choice has to reach the restart, whatever
  /// storage did.
  final List<QualityRung> inEffectAtRestart = [];

  QualityRung? adopted;
  final List<QualityRung> adoptedRungs = [];
  final List<QualityRung> remembered = [];
  final List<_RestartCall> restarts = [];
  final List<Object> gaveUp = [];

  void adopt(QualityRung rung) {
    adopted = rung;
    adoptedRungs.add(rung);
  }

  Future<void> remember(QualityRung rung) async {
    if (storageFails) {
      throw StateError('secure storage is unavailable');
    }
    remembered.add(rung);
  }

  Future<bool> restart(QualityRung rung, {required bool isFallback}) async {
    final index = restarts.length;
    restarts.add(_RestartCall(rung, isFallback));
    inEffectAtRestart.add(adopted ?? QualityRung.original);
    if (failing.contains(index)) {
      throw StateError('restart #$index refused ${rung.label}');
    }
    return !abandoned.contains(index);
  }

  bool stillActive() => active;

  void onGaveUp(Object error) => gaveUp.add(error);

  Future<void> run() => applyQualityChoice(
        selected: _selected,
        previous: _previous,
        adopt: adopt,
        remember: remember,
        restart: restart,
        stillActive: stillActive,
        onGaveUp: onGaveUp,
      );
}

void main() {
  test('a choice that works adopts it, remembers it, and restarts once',
      () async {
    final recorder = _Recorder();

    await recorder.run();

    expect(recorder.adoptedRungs, [_selected]);
    expect(recorder.remembered, [_selected]);
    expect(recorder.restarts.map((c) => c.rung), [_selected]);
    expect(recorder.restarts.single.isFallback, isFalse,
        reason: 'the first attempt is what the viewer asked for, and is told '
            'so; only the rollback is a fallback');
    expect(recorder.gaveUp, isEmpty);
  });

  test(
      'adopts in memory before restarting, and remembers only after the '
      'restart lands', () async {
    // Ordering is load-bearing rather than cosmetic. `_resolveQualityForFile`
    // carries the in-memory rung into the session it negotiates, so a restart
    // that ran before `adopt` would request the *old* rung and the viewer's
    // choice would silently not apply. Persisting before the restart lands
    // could race a fallback that starts mid-await and store a rung that
    // never actually played.
    final order = <String>[];
    await applyQualityChoice(
      selected: _selected,
      previous: _previous,
      adopt: (rung) => order.add('adopt:${rung.label}'),
      remember: (rung) async => order.add('remember:${rung.label}'),
      restart: (rung, {required bool isFallback}) async {
        order.add('restart:${rung.label}');
        return true;
      },
      stillActive: () => true,
      onGaveUp: (_) {},
    );

    expect(order, ['adopt:720p', 'restart:720p', 'remember:720p']);
  });

  test('remember runs only after a successful restart, never before it',
      () async {
    final recorder = _Recorder();
    var rememberedBeforeRestart = <QualityRung>[];

    await applyQualityChoice(
      selected: _selected,
      previous: _previous,
      adopt: recorder.adopt,
      remember: recorder.remember,
      restart: (rung, {required bool isFallback}) async {
        rememberedBeforeRestart = List.of(recorder.remembered);
        return recorder.restart(rung, isFallback: isFallback);
      },
      stillActive: recorder.stillActive,
      onGaveUp: recorder.onGaveUp,
    );

    expect(rememberedBeforeRestart, isEmpty,
        reason: 'nothing is persisted until the restart has reported success');
    expect(recorder.remembered, [_selected]);
  });

  test('a restart still gets the chosen rung when persistence fails', () async {
    // The regression this split exists for. The choice used to reach the
    // restart *through* secure storage, whose write failure is deliberately
    // swallowed, so a locked keyring meant the session came back at the rung
    // the viewer had just replaced — a restart that visibly changed nothing.
    final recorder = _Recorder(storageFails: true);

    await recorder.run();

    expect(recorder.remembered, isEmpty, reason: 'the write threw');
    expect(recorder.restarts.map((c) => c.rung), [_selected],
        reason: 'the restart happens anyway; losing the preference for next '
            'time is not a reason to abandon this playback');
    expect(recorder.inEffectAtRestart, [_selected],
        reason: 'and it runs with the chosen rung in effect, not the old one');
    expect(recorder.gaveUp, isEmpty);
  });

  test('a failing choice restores the previous rung and retries once',
      () async {
    final recorder = _Recorder(failing: {0});

    await recorder.run();

    expect(recorder.adoptedRungs, [_selected, _previous],
        reason: 'the rung that was working has to be back in effect, or the '
            'retry re-requests the failing one');
    expect(recorder.remembered, [_previous],
        reason: 'the failed restart never put `_selected` into effect, so '
            'there is nothing about it worth remembering; the rollback that '
            'did land is the only thing worth keeping');
    expect(recorder.restarts.map((c) => c.rung), [_selected, _previous]);
    expect(recorder.inEffectAtRestart, [_selected, _previous]);
    expect(recorder.restarts.last.isFallback, isTrue);
    expect(recorder.gaveUp, isEmpty,
        reason: 'the rollback succeeded, so the viewer keeps watching and '
            'never sees the error screen');
  });

  test('the rollback survives a storage failure too', () async {
    final recorder = _Recorder(failing: {0}, storageFails: true);

    await recorder.run();

    expect(recorder.restarts.map((c) => c.rung), [_selected, _previous]);
    expect(recorder.inEffectAtRestart, [_selected, _previous],
        reason: 'an unwritable keyring must not strand the viewer at a rung '
            'that could not be served');
    expect(recorder.gaveUp, isEmpty);
  });

  test(
      'a restart that reports false is abandoned quietly: no persist, no '
      'rollback, no giving up', () async {
    // Another source switch (a fallback, a seek restart) took over while
    // this one was mid-flight; `restart` says so by returning `false`
    // instead of throwing. Retrying against it or persisting a rung that
    // never took effect would both be wrong.
    final recorder = _Recorder(abandoned: {0});

    await recorder.run();

    expect(recorder.restarts, hasLength(1),
        reason: 'no rollback: the first attempt was not a failure, just '
            'pre-empted');
    expect(recorder.remembered, isEmpty);
    expect(recorder.gaveUp, isEmpty);
  });

  test('a rollback that reports false persists nothing and does not give up',
      () async {
    final recorder = _Recorder(failing: {0}, abandoned: {1});

    await recorder.run();

    expect(recorder.restarts, hasLength(2));
    expect(recorder.remembered, isEmpty,
        reason: 'neither the failed first attempt nor the pre-empted '
            'rollback ever took effect');
    expect(recorder.gaveUp, isEmpty,
        reason: 'the rollback was pre-empted, not a second failure; there is '
            'nothing to show an error for');
  });

  test('a second failure gives up instead of retrying again', () async {
    final recorder = _Recorder(failing: {0, 1});

    await recorder.run();

    expect(recorder.restarts, hasLength(2),
        reason: 'exactly two teardowns, ever: another one would only cost '
            'the viewer more time before showing them the same error');
    expect(recorder.gaveUp, hasLength(1));
    expect(recorder.gaveUp.single, isA<StateError>());
  });

  test('does not rethrow when both attempts fail', () async {
    // The caller invokes this from a `VoidCallback` on the chrome, where an
    // escaping exception becomes an unhandled async error rather than
    // anything the viewer can act on. `onGaveUp` is the whole exit path.
    final recorder = _Recorder(failing: {0, 1});

    await expectLater(recorder.run(), completes);
  });

  test('stops without rolling back when the caller is gone', () async {
    // The widget was disposed mid-restart. Adopting and restarting against
    // a dead `State` is at best wasted work and at worst a `setState` after
    // dispose.
    final recorder = _Recorder(failing: {0})..active = false;

    await recorder.run();

    expect(recorder.adoptedRungs, [_selected]);
    expect(recorder.restarts, hasLength(1));
    expect(recorder.gaveUp, isEmpty);
  });

  test('stops before giving up when the caller disappears mid-rollback',
      () async {
    final recorder = _Recorder(failing: {0, 1});
    // Still alive for the rollback decision, gone by the time it has failed.
    var checks = 0;
    await applyQualityChoice(
      selected: _selected,
      previous: _previous,
      adopt: recorder.adopt,
      remember: recorder.remember,
      restart: recorder.restart,
      stillActive: () => ++checks == 1,
      onGaveUp: recorder.onGaveUp,
    );

    expect(recorder.restarts, hasLength(2));
    expect(recorder.gaveUp, isEmpty,
        reason: 'no error screen to put it on; the widget is gone');
  });

  group('qualityPickNeedsReopen', () {
    const directPlay = DirectPlayPlan(reason: PlanReason.directPlayAccepted);
    const otherDirectPlay =
        DirectPlayPlan(reason: PlanReason.fallbackFromFailure);
    const copy720 = HlsPlan(
      strategy: HlsStrategy.copy,
      rung: QualityRung.original,
      adaptive: false,
      reason: PlanReason.copyAccepted,
    );

    test('same delivery on a first attempt needs no reopen', () {
      expect(
        qualityPickNeedsReopen(
          next: directPlay,
          current: otherDirectPlay,
          isFallback: false,
        ),
        isFalse,
      );
    });

    test('same delivery on a rollback needs a reopen', () {
      // The attempt the rollback undoes may already have moved the player
      // onto failing media before it threw, so the plan on record cannot be
      // trusted to describe what is actually on screen.
      expect(
        qualityPickNeedsReopen(
          next: directPlay,
          current: otherDirectPlay,
          isFallback: true,
        ),
        isTrue,
      );
    });

    test('different delivery needs a reopen', () {
      expect(
        qualityPickNeedsReopen(
          next: directPlay,
          current: copy720,
          isFallback: false,
        ),
        isTrue,
      );
    });

    test('no current plan needs a reopen', () {
      expect(
        qualityPickNeedsReopen(
          next: directPlay,
          current: null,
          isFallback: false,
        ),
        isTrue,
      );
    });
  });
}
