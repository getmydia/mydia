import 'dart:async';

import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/remote/ambient_lifecycle.dart';
import 'package:player/core/remote/ambient_targets.dart';
import 'package:player/native/lib.dart';

import 'ambient_targets_test.dart' hide main;

void main() {
  group('ambientLifecycleAction', () {
    // Pinned directly, without a widget tree or the real OS-driven
    // lifecycle, the same reasoning `resume_gate_test.dart` gives for
    // `applyAppLifecycleState`: a typo folding `inactive` into the
    // background case would turn a notification shade pull into churn
    // that drops and immediately re-establishes every held connection.

    test('paused, detached, and hidden all count as background', () {
      expect(ambientLifecycleAction(AppLifecycleState.paused),
          AmbientLifecycleAction.background);
      expect(ambientLifecycleAction(AppLifecycleState.detached),
          AmbientLifecycleAction.background);
      expect(ambientLifecycleAction(AppLifecycleState.hidden),
          AmbientLifecycleAction.background,
          reason: '`paused` is mobile-only per its own dartdoc; `hidden` is '
              'the only backgrounding signal Flutter Web (this app\'s '
              'primary deployment per player/CLAUDE.md) ever reaches');
    });

    test('resumed counts as foreground', () {
      expect(ambientLifecycleAction(AppLifecycleState.resumed),
          AmbientLifecycleAction.foreground);
    });

    test('inactive has no opinion, to avoid churn on transient interrupts', () {
      expect(ambientLifecycleAction(AppLifecycleState.inactive),
          AmbientLifecycleAction.none);
    });
  });

  group('AmbientLifecycleBinding', () {
    test('a background transition drops every held target', () async {
      final scripted = ScriptedProbe({
        'node-tv': playingSnapshot(title: 'Blade Runner'),
      });
      final targets = AmbientTargets(
        rosterSource: rosterOf(['node-tv']),
        probe: scripted.call,
      );
      addTearDown(targets.dispose);
      final binding = AmbientLifecycleBinding(() => targets);

      await targets.sweep();
      expect(await targets.playing.first, isNotEmpty);

      binding.handle(AppLifecycleState.paused);

      expect(await targets.playing.first, isEmpty);
    });

    test('a foreground transition re-sweeps, repopulating held targets',
        () async {
      final scripted = ScriptedProbe({
        'node-tv': playingSnapshot(title: 'Blade Runner'),
      });
      final targets = AmbientTargets(
        rosterSource: rosterOf(['node-tv']),
        probe: scripted.call,
      );
      addTearDown(targets.dispose);
      final binding = AmbientLifecycleBinding(() => targets);

      binding.handle(AppLifecycleState.paused);
      expect(await targets.playing.first, isEmpty);

      binding.handle(AppLifecycleState.resumed);
      // sweep() is async; let its microtask chain settle.
      await Future<void>.delayed(Duration.zero);

      expect(await targets.playing.first, isNotEmpty,
          reason: 'recovery is the next foreground sweep');
    });

    test('inactive does not drop held targets', () async {
      final scripted = ScriptedProbe({
        'node-tv': playingSnapshot(title: 'Blade Runner'),
      });
      final targets = AmbientTargets(
        rosterSource: rosterOf(['node-tv']),
        probe: scripted.call,
      );
      addTearDown(targets.dispose);
      final binding = AmbientLifecycleBinding(() => targets);

      await targets.sweep();
      expect(await targets.playing.first, isNotEmpty);

      binding.handle(AppLifecycleState.inactive);

      expect(await targets.playing.first, isNotEmpty,
          reason: 'a notification shade pull must not tear down a held '
              'connection');
    });

    test('a background -> foreground -> background cycle repeats cleanly',
        () async {
      final scripted = ScriptedProbe({
        'node-tv': playingSnapshot(title: 'Blade Runner'),
      });
      final targets = AmbientTargets(
        rosterSource: rosterOf(['node-tv']),
        probe: scripted.call,
      );
      addTearDown(targets.dispose);
      final binding = AmbientLifecycleBinding(() => targets);

      await targets.sweep();
      expect(await targets.playing.first, isNotEmpty);

      binding.handle(AppLifecycleState.paused);
      expect(await targets.playing.first, isEmpty);

      binding.handle(AppLifecycleState.resumed);
      await Future<void>.delayed(Duration.zero);
      expect(await targets.playing.first, isNotEmpty);

      binding.handle(AppLifecycleState.detached);
      expect(await targets.playing.first, isEmpty);

      binding.handle(AppLifecycleState.resumed);
      await Future<void>.delayed(Duration.zero);
      expect(await targets.playing.first, isNotEmpty);
    });

    test(
        "an external sweep() (e.g. ambientPlayingProvider's 30-second "
        'resweep timer) while backgrounded does not undo onBackground()',
        () async {
      final scripted = ScriptedProbe({
        'node-tv': playingSnapshot(title: 'Blade Runner'),
      });
      final targets = AmbientTargets(
        rosterSource: rosterOf(['node-tv']),
        probe: scripted.call,
      );
      addTearDown(targets.dispose);
      final binding = AmbientLifecycleBinding(() => targets);

      await targets.sweep();
      expect(await targets.playing.first, isNotEmpty);

      binding.handle(AppLifecycleState.paused);
      expect(await targets.playing.first, isEmpty);

      // Something other than the binding — in production,
      // `ambientPlayingProvider`'s own resweep `Timer.periodic`
      // (`cast_providers.dart`), which keeps firing for as long as
      // `CastMiniController` holds a listener, background included — calls
      // plain `sweep()` directly, bypassing the binding entirely.
      await targets.sweep();

      expect(await targets.playing.first, isEmpty,
          reason: 'a stray sweep() from outside the binding must stay '
              'inert while backgrounded, no matter which timer fired it');

      // The binding itself must still recover normally afterwards.
      binding.handle(AppLifecycleState.resumed);
      await Future<void>.delayed(Duration.zero);

      expect(await targets.playing.first, isNotEmpty,
          reason: 'ambient must still recover on the next genuine '
              'foreground transition');
    });

    test(
        'a background arriving while a foreground sweep is still in flight '
        'wins: the late sweep does not leave connections open', () async {
      final probeCompleter = Completer<FlutterPlaybackSnapshot?>();
      var probeCalls = 0;
      final targets = AmbientTargets(
        rosterSource: rosterOf(['node-tv']),
        probe: (nodeId) {
          probeCalls++;
          return probeCompleter.future;
        },
      );
      addTearDown(targets.dispose);
      final binding = AmbientLifecycleBinding(() => targets);

      binding.handle(AppLifecycleState.resumed);
      // Let sweep() reach and start awaiting the probe, but no further.
      await Future<void>.delayed(Duration.zero);
      expect(probeCalls, 1);

      // The app backgrounds again before that sweep's probe answers.
      binding.handle(AppLifecycleState.paused);
      expect(await targets.playing.first, isEmpty);

      // The stale sweep's probe finally answers "playing".
      probeCompleter.complete(playingSnapshot(title: 'Blade Runner'));
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(await targets.playing.first, isEmpty,
          reason: "the sweep resolved after the app backgrounded again; "
              "AmbientTargets itself has no way to cancel it, so the "
              'binding must notice and re-apply onBackground() rather than '
              'leave the stale sweep\'s connection open');
    });

    test('handle() after dispose() does not throw', () async {
      final scripted = ScriptedProbe({
        'node-tv': playingSnapshot(title: 'Blade Runner'),
      });
      final targets = AmbientTargets(
        rosterSource: rosterOf(['node-tv']),
        probe: scripted.call,
      );
      final binding = AmbientLifecycleBinding(() => targets);

      await targets.sweep();
      await targets.dispose();

      // Neither branch may throw once the underlying AmbientTargets is
      // gone — a lifecycle callback has nowhere to report a failure to.
      expect(() => binding.handle(AppLifecycleState.paused), returnsNormally);
      binding.handle(AppLifecycleState.resumed);
      await Future<void>.delayed(Duration.zero);
    });

    test('targets() resolving to null (p2p not ready yet) is a no-op',
        () async {
      final binding = AmbientLifecycleBinding(() => null);

      expect(() => binding.handle(AppLifecycleState.paused), returnsNormally);
      expect(() => binding.handle(AppLifecycleState.resumed), returnsNormally);
      await Future<void>.delayed(Duration.zero);
    });

    test(
        'a roster fetch that throws inside sweep() does not escape as an '
        'unhandled async error', () async {
      // `rosterSource` stands in for the real GraphQL roster fetch
      // (`ambientTargetsProvider` in `core/cast/cast_providers.dart` builds
      // it from `RemoteRoster.entries()`), which can throw on a network or
      // auth failure. `sweep()`'s caller here is `unawaited(...)` with no
      // error path of its own, so without a `catchError` this throw would
      // become an unhandled async error and fail this test even though
      // nothing in the test body itself is wrong.
      final targets = AmbientTargets(
        rosterSource: () async => throw StateError('roster fetch failed'),
        probe: (nodeId) async => null,
      );
      addTearDown(targets.dispose);
      final binding = AmbientLifecycleBinding(() => targets);

      binding.handle(AppLifecycleState.resumed);

      // Give the failing sweep's microtask chain a chance to run — and, if
      // the error were unhandled, to fail this test on its own.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(await targets.playing.first, isEmpty,
          reason: 'a failed sweep leaves nothing held, but must not crash');
    });

    test(
        'a background transition landing while a failing sweep is still in '
        'flight still calls onBackground()', () async {
      final rosterGate = Completer<List<String>>();
      final targets = AmbientTargets(
        rosterSource: () => rosterGate.future,
        probe: (nodeId) async => playingSnapshot(title: 'Blade Runner'),
      );
      addTearDown(targets.dispose);
      final binding = AmbientLifecycleBinding(() => targets);

      binding.handle(AppLifecycleState.resumed);
      await Future<void>.delayed(Duration.zero);

      // The app backgrounds again while the sweep is still awaiting the
      // roster fetch.
      binding.handle(AppLifecycleState.paused);

      // Now the roster fetch fails, well after the background transition
      // landed.
      rosterGate.completeError(StateError('roster fetch failed'));
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(await targets.playing.first, isEmpty,
          reason: 'the background transition must still win even though '
              'the sweep it interrupted went on to fail rather than '
              'succeed');
    });
  });
}
