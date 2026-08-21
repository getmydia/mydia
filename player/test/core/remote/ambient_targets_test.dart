import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/remote/ambient_targets.dart';
import 'package:player/native/lib.dart';

/// An [AmbientProbe] that answers from a fixed script rather than dialing a
/// real target, keyed by node ID exactly like the production probe's result
/// (see `ambient_targets.dart`'s `AmbientProbe` doc).
AmbientProbe scriptedProbe(Map<String, FlutterPlaybackSnapshot?> answers) =>
    () async => answers;

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
      final targets = AmbientTargets(
          probe: scriptedProbe({
        'node-tv': playingSnapshot(title: 'Blade Runner'),
        'node-phone': null,
      }));
      addTearDown(targets.dispose);

      await targets.sweep();

      final held = await targets.playing.first;
      expect(held.map((t) => t.device.id), ['node-tv']);
      expect(held.single.snapshot.title, 'Blade Runner');
    });

    test('does not hold connections to idle devices', () async {
      final targets = AmbientTargets(
          probe: scriptedProbe({
        'node-tv': null,
        'node-phone': null,
      }));
      addTearDown(targets.dispose);

      await targets.sweep();

      expect(await targets.playing.first, isEmpty);
    });

    test('caps held connections at three to bound cost', () async {
      final targets = AmbientTargets(
          probe: scriptedProbe({
        for (var i = 0; i < 6; i++)
          'node-$i': playingSnapshot(title: 'Item $i'),
      }));
      addTearDown(targets.dispose);

      await targets.sweep();

      expect((await targets.playing.first).length, 3);
    });

    test('drops every held connection when the app backgrounds', () async {
      final targets = AmbientTargets(
          probe: scriptedProbe({
        'node-tv': playingSnapshot(title: 'Blade Runner'),
      }));
      addTearDown(targets.dispose);

      await targets.sweep();
      expect(await targets.playing.first, isNotEmpty);

      targets.onBackground();

      // Recovery is the next foreground sweep, not a reconnect loop.
      expect(await targets.playing.first, isEmpty);
    });
  });
}
