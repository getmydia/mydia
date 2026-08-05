// Unit coverage for `applyQualityChoice`, the decision behind the quality
// picker: put the chosen rung into effect, and if that fails, put the one
// that was already working back and try exactly once more.
//
// Extracted from `_showQualitySelector` and tested here rather than through
// the widget for the reason spelled out on the function itself: the chrome
// that owns the quality button is never built under `flutter test`, because
// `_waitForPlaylist` polls a real URL that `flutter_test`'s `HttpOverrides`
// answers with 400 every time, so the screen reaches its error state first.
// Same precedent as `trackRestartInFlight` and `shouldRestartForSeek`, both
// pulled out of this file for the same reason.

import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/models/quality_rung.dart';
import 'package:player/presentation/screens/player/player_screen.dart';

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

/// Records every callback `applyQualityChoice` makes, and fails whichever
/// restarts [failing] names.
class _Recorder {
  _Recorder({this.failing = const <int>{}});

  /// Zero-based indices of `restart` calls that throw.
  final Set<int> failing;

  /// Stands in for the widget still being mounted. Set through a cascade at
  /// the call site rather than the constructor, since only one test cares.
  bool active = true;

  final List<QualityRung> persisted = [];
  final List<_RestartCall> restarts = [];
  final List<Object> gaveUp = [];

  Future<void> persist(QualityRung rung) async => persisted.add(rung);

  Future<void> restart(QualityRung rung, {required bool isFallback}) async {
    final index = restarts.length;
    restarts.add(_RestartCall(rung, isFallback));
    if (failing.contains(index)) {
      throw StateError('restart #$index refused ${rung.label}');
    }
  }

  bool stillActive() => active;

  void onGaveUp(Object error) => gaveUp.add(error);

  Future<void> run() => applyQualityChoice(
        selected: _selected,
        previous: _previous,
        persist: persist,
        restart: restart,
        stillActive: stillActive,
        onGaveUp: onGaveUp,
      );
}

void main() {
  test('a choice that works persists it and restarts once', () async {
    final recorder = _Recorder();

    await recorder.run();

    expect(recorder.persisted, [_selected]);
    expect(recorder.restarts.map((c) => c.rung), [_selected]);
    expect(recorder.restarts.single.isFallback, isFalse,
        reason: 'the first attempt is what the viewer asked for, and is told '
            'so; only the rollback is a fallback');
    expect(recorder.gaveUp, isEmpty);
  });

  test('persists before restarting, not after', () async {
    // Ordering is load-bearing rather than cosmetic: `_initializePlayer`
    // re-reads the stored rung on its way through, so a restart that ran
    // before the write would negotiate the session at the *old* rung and the
    // viewer's choice would silently not apply.
    final order = <String>[];
    await applyQualityChoice(
      selected: _selected,
      previous: _previous,
      persist: (rung) async => order.add('persist:${rung.label}'),
      restart: (rung, {required bool isFallback}) async =>
          order.add('restart:${rung.label}'),
      stillActive: () => true,
      onGaveUp: (_) {},
    );

    expect(order, ['persist:720p', 'restart:720p']);
  });

  test('a failing choice restores the previous rung and retries once',
      () async {
    final recorder = _Recorder(failing: {0});

    await recorder.run();

    expect(recorder.persisted, [_selected, _previous],
        reason: 'the rung that was working has to be stored again, or the '
            'retry re-reads the failing one');
    expect(recorder.restarts.map((c) => c.rung), [_selected, _previous]);
    expect(recorder.restarts.last.isFallback, isTrue);
    expect(recorder.gaveUp, isEmpty,
        reason: 'the rollback succeeded, so the viewer keeps watching and '
            'never sees the error screen');
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
    // The widget was disposed mid-restart. Persisting and restarting against
    // a dead `State` is at best wasted work and at worst a `setState` after
    // dispose.
    final recorder = _Recorder(failing: {0})..active = false;

    await recorder.run();

    expect(recorder.persisted, [_selected]);
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
      persist: recorder.persist,
      restart: recorder.restart,
      stillActive: () => ++checks == 1,
      onGaveUp: recorder.onGaveUp,
    );

    expect(recorder.restarts, hasLength(2));
    expect(recorder.gaveUp, isEmpty,
        reason: 'no error screen to put it on; the widget is gone');
  });
}
