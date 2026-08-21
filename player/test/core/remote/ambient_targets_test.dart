import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/remote/ambient_targets.dart';
import 'package:player/native/lib.dart';

/// An [AmbientRosterSource] that answers with a fixed list of node IDs.
AmbientRosterSource rosterOf(List<String> ids) => () async => ids;

/// An [AmbientNodeProbe] that answers per node ID from a swappable script,
/// keyed exactly like the production probe's argument (see
/// `ambient_targets.dart`'s `AmbientNodeProbe` doc), and records how many
/// times each ID was probed. The call counts are how the tests below prove
/// the 5-second refresh dials only the held IDs, never the whole roster.
class ScriptedProbe {
  ScriptedProbe(this._answers);

  Map<String, FlutterPlaybackSnapshot?> _answers;
  final Map<String, int> callCounts = {};

  /// Swaps in a new answer set, e.g. to simulate a device stopping or
  /// starting playback between ticks.
  void update(Map<String, FlutterPlaybackSnapshot?> answers) {
    _answers = answers;
  }

  Future<FlutterPlaybackSnapshot?> call(String nodeId) async {
    callCounts[nodeId] = (callCounts[nodeId] ?? 0) + 1;
    return _answers[nodeId];
  }
}

/// A [FlutterPlaybackSnapshot] with sensible defaults for every required
/// field, so a test only has to spell out the title it cares about.
FlutterPlaybackSnapshot playingSnapshot({required String title}) =>
    FlutterPlaybackSnapshot(
      state: FlutterPlaybackState.playing,
      title: title,
      positionMs: BigInt.zero,
      durationMs: BigInt.from(60000),
      muted: false,
      audioTracks: const [],
      subtitleTracks: const [],
      capabilities: const FlutterTargetCapabilities(
        volume: true,
        trackSelection: true,
        nextPrevious: false,
      ),
      sequence: BigInt.one,
    );

void main() {
  group('AmbientTargets', () {
    test('holds a connection open to a target that is playing', () async {
      final scripted = ScriptedProbe({
        'node-tv': playingSnapshot(title: 'Blade Runner'),
        'node-phone': null,
      });
      final targets = AmbientTargets(
        rosterSource: rosterOf(['node-tv', 'node-phone']),
        probe: scripted.call,
      );
      addTearDown(targets.dispose);

      await targets.sweep();

      final held = await targets.playing.first;
      expect(held.map((t) => t.device.id), ['node-tv']);
      expect(held.single.snapshot.title, 'Blade Runner');
    });

    test('does not hold connections to idle devices', () async {
      final scripted = ScriptedProbe({
        'node-tv': null,
        'node-phone': null,
      });
      final targets = AmbientTargets(
        rosterSource: rosterOf(['node-tv', 'node-phone']),
        probe: scripted.call,
      );
      addTearDown(targets.dispose);

      await targets.sweep();

      expect(await targets.playing.first, isEmpty);
    });

    test(
        'caps held connections at three, keeping the first three in roster order',
        () async {
      final ids = [for (var i = 0; i < 6; i++) 'node-$i'];
      final scripted = ScriptedProbe({
        for (final id in ids) id: playingSnapshot(title: id),
      });
      final targets = AmbientTargets(
        rosterSource: rosterOf(ids),
        probe: scripted.call,
      );
      addTearDown(targets.dispose);

      await targets.sweep();

      final held = await targets.playing.first;
      // Not just the count: an accidental `.reversed` or set-ordering
      // change would still pass a length-only assertion.
      expect(held.map((t) => t.device.id), ['node-0', 'node-1', 'node-2']);
    });

    test('drops every held connection when the app backgrounds', () async {
      final scripted = ScriptedProbe({
        'node-tv': playingSnapshot(title: 'Blade Runner'),
      });
      final targets = AmbientTargets(
        rosterSource: rosterOf(['node-tv']),
        probe: scripted.call,
      );
      addTearDown(targets.dispose);

      await targets.sweep();
      expect(await targets.playing.first, isNotEmpty);

      targets.onBackground();

      // Recovery is the next foreground sweep, not a reconnect loop.
      expect(await targets.playing.first, isEmpty);
    });

    test(
        'a 5-second refresh tick probes only the held nodes, not the whole '
        'roster', () {
      fakeAsync((async) {
        final ids = [for (var i = 0; i < 6; i++) 'node-$i'];
        final scripted = ScriptedProbe({
          for (final id in ids) id: playingSnapshot(title: id),
        });
        final targets = AmbientTargets(
          rosterSource: rosterOf(ids),
          probe: scripted.call,
        );

        unawaited(targets.sweep());
        async.flushMicrotasks();

        // The sweep dialed every one of the 6 rostered nodes exactly once.
        expect(scripted.callCounts.length, 6);
        expect(scripted.callCounts.values.every((c) => c == 1), isTrue);

        async.elapse(const Duration(seconds: 5));

        // The refresh tick re-dialed only the three held nodes — this is
        // the regression test for the cap trimming the *dial*, not just
        // the returned result. Without it, Fix 1 could silently revert to
        // re-probing all 6 every tick.
        expect(scripted.callCounts['node-0'], 2);
        expect(scripted.callCounts['node-1'], 2);
        expect(scripted.callCounts['node-2'], 2);
        expect(scripted.callCounts['node-3'], 1,
            reason: 'never held, so never re-dialed');
        expect(scripted.callCounts['node-4'], 1,
            reason: 'never held, so never re-dialed');
        expect(scripted.callCounts['node-5'], 1,
            reason: 'never held, so never re-dialed');

        // fakeAsync tests dispose inside the zone that started the timer —
        // never via `addTearDown`, which would run in real time after this
        // zone exits and hang closing a controller the fake zone already
        // closed (see the `fake_async` interaction this pattern avoids in
        // `test/core/cast/mydia_cast_backend_test.dart`).
        targets.dispose();
      });
    });

    test('drops a held target on the next tick once it stops reporting playing',
        () {
      fakeAsync((async) {
        final scripted = ScriptedProbe({
          'node-tv': playingSnapshot(title: 'Blade Runner'),
        });
        final targets = AmbientTargets(
          rosterSource: rosterOf(['node-tv']),
          probe: scripted.call,
        );

        List<AmbientTarget>? latest;
        targets.playing.listen((held) => latest = held);

        unawaited(targets.sweep());
        async.flushMicrotasks();
        expect(latest?.map((t) => t.device.id), ['node-tv']);

        scripted.update({'node-tv': null});
        async.elapse(const Duration(seconds: 5));

        expect(latest, isEmpty);

        targets.dispose();
      });
    });

    test(
        'a device that starts playing mid-poll stays invisible across ticks '
        'until the next sweep', () {
      fakeAsync((async) {
        final scripted = ScriptedProbe({
          'node-tv': playingSnapshot(title: 'Blade Runner'),
          'node-phone': null,
        });
        final targets = AmbientTargets(
          rosterSource: rosterOf(['node-tv', 'node-phone']),
          probe: scripted.call,
        );

        List<AmbientTarget>? latest;
        targets.playing.listen((held) => latest = held);

        unawaited(targets.sweep());
        async.flushMicrotasks();
        expect(latest?.map((t) => t.device.id), ['node-tv']);

        // node-phone starts playing after the sweep — purely between poll
        // ticks, with no new sweep() in between.
        scripted.update({
          'node-tv': playingSnapshot(title: 'Blade Runner'),
          'node-phone': playingSnapshot(title: 'Arrival'),
        });

        async.elapse(const Duration(seconds: 5));
        expect(latest?.map((t) => t.device.id), ['node-tv'],
            reason: 'membership only changes via sweep(), never mid-poll');

        async.elapse(const Duration(seconds: 5));
        expect(latest?.map((t) => t.device.id), ['node-tv'],
            reason: 'still invisible on a second tick');

        // node-phone was never held, so the refresh never dialed it either
        // — the poll genuinely never saw it, not just filtered it out.
        expect(scripted.callCounts['node-phone'], 1,
            reason: 'only the original sweep() probed it');

        targets.dispose();
      });
    });

    test(
        'a sweep() arriving while backgrounded (e.g. the 30-second ambient '
        'resweep timer in cast_providers.dart) does not repopulate held '
        'targets or resume polling', () {
      fakeAsync((async) {
        final scripted = ScriptedProbe({
          'node-tv': playingSnapshot(title: 'Blade Runner'),
        });
        final targets = AmbientTargets(
          rosterSource: rosterOf(['node-tv']),
          probe: scripted.call,
        );

        List<AmbientTarget>? latest;
        targets.playing.listen((held) => latest = held);

        unawaited(targets.sweep());
        async.flushMicrotasks();
        expect(latest?.map((t) => t.device.id), ['node-tv']);
        expect(scripted.callCounts['node-tv'], 1);

        targets.onBackground();
        async.flushMicrotasks();
        expect(latest, isEmpty);

        // Simulate `ambientPlayingProvider`'s own resweep `Timer.periodic`,
        // which keeps calling plain `sweep()` for as long as
        // `CastMiniController` is mounted — i.e. permanently, background
        // included — by firing `sweep()` again once that timer's interval
        // has elapsed.
        async.elapse(const Duration(seconds: 30));
        unawaited(targets.sweep());
        async.flushMicrotasks();

        expect(scripted.callCounts['node-tv'], 1,
            reason: 'a backgrounded sweep() must not even dial the roster, '
                'let alone repopulate');
        expect(latest, isEmpty,
            reason: 'still dropped: the resweep must not have undone '
                'onBackground()');

        // No poll timer resumed either: elapsing another 5-second tick must
        // not trigger any further probe calls.
        async.elapse(const Duration(seconds: 5));
        expect(scripted.callCounts['node-tv'], 1,
            reason: 'no poll timer should have restarted');

        targets.dispose();
      });
    });

    test(
        'never calls probe again after dispose, even after a long elapsed time',
        () {
      fakeAsync((async) {
        final scripted = ScriptedProbe({
          'node-tv': playingSnapshot(title: 'Blade Runner'),
        });
        final targets = AmbientTargets(
          rosterSource: rosterOf(['node-tv']),
          probe: scripted.call,
        );

        unawaited(targets.sweep());
        async.flushMicrotasks();
        final countAtSweep = scripted.callCounts['node-tv'];

        unawaited(targets.dispose());
        async.flushMicrotasks();

        async.elapse(const Duration(minutes: 30));

        expect(scripted.callCounts['node-tv'], countAtSweep);
      });
    });
  });
}
