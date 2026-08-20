import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/remote/remote_control_intent.dart';
import 'package:player/core/remote/remote_target_controller.dart';
import 'package:player/native/lib.dart';

class FakePlayerBinding implements RemotePlayerBinding {
  final calls = <String>[];
  Duration position = const Duration(minutes: 5);
  bool playing = true;

  @override
  Future<void> play() async {
    calls.add('play');
    playing = true;
  }

  @override
  Future<void> pause() async {
    calls.add('pause');
    playing = false;
  }

  @override
  Future<void> stop() async => calls.add('stop');

  @override
  Future<void> seek(Duration to) async {
    calls.add('seek:${to.inMilliseconds}');
    position = to;
  }

  @override
  Future<void> setVolume(double level) async => calls.add('volume:$level');

  @override
  Future<void> setMuted(bool muted) async => calls.add('muted:$muted');

  @override
  Future<void> selectTrack(TrackKind kind, String? id) async =>
      calls.add('track:${kind.name}:$id');

  @override
  Future<void> stepEpisode(EpisodeStep step) async =>
      calls.add('episode:${step.name}');

  @override
  FlutterPlaybackSnapshot describe(int sequence) => FlutterPlaybackSnapshot(
        state: playing
            ? FlutterPlaybackState.playing
            : FlutterPlaybackState.paused,
        mediaItemId: 'item-1',
        episodeId: null,
        title: 'Blade Runner',
        subtitle: null,
        imageUrl: null,
        positionMs: BigInt.from(position.inMilliseconds),
        durationMs: BigInt.from(6960000),
        volume: 0.8,
        muted: false,
        audioTracks: const [],
        subtitleTracks: const [],
        selectedAudio: null,
        selectedSubtitle: null,
        capabilities: const FlutterTargetCapabilities(
          volume: true,
          trackSelection: true,
          nextPrevious: true,
        ),
        sequence: BigInt.from(sequence),
      );
}

void main() {
  group('RemoteTargetController', () {
    test('reports no snapshot when no player is attached', () {
      final controller = RemoteTargetController();
      expect(controller.snapshot(), isNull);
    });

    test('describes the attached player', () {
      final controller = RemoteTargetController();
      controller.attachPlayer(FakePlayerBinding());

      final snapshot = controller.snapshot();

      expect(snapshot, isNotNull);
      expect(snapshot!.title, 'Blade Runner');
      expect(snapshot.state, FlutterPlaybackState.playing);
    });

    test('advances the sequence on every snapshot so pollers can order them',
        () {
      final controller = RemoteTargetController();
      controller.attachPlayer(FakePlayerBinding());

      final first = controller.snapshot()!.sequence;
      final second = controller.snapshot()!.sequence;

      expect(second, greaterThan(first));
    });

    test('drives the attached player from a transport intent', () async {
      final controller = RemoteTargetController();
      final binding = FakePlayerBinding();
      controller.attachPlayer(binding);

      controller.submit(const TransportIntent(
        TransportAction.seek,
        position: Duration(milliseconds: 754000),
      ));
      await Future<void>.delayed(Duration.zero);

      expect(binding.calls, ['seek:754000']);
    });

    test('drives volume and track selection', () async {
      final controller = RemoteTargetController();
      final binding = FakePlayerBinding();
      controller.attachPlayer(binding);

      controller.submit(const VolumeIntent(level: 0.4));
      controller.submit(
          const TrackSelectionIntent(kind: TrackKind.subtitle, trackId: null));
      await Future<void>.delayed(Duration.zero);

      expect(binding.calls, ['volume:0.4', 'track:subtitle:null']);
    });

    test('publishes LoadContent on the intent stream rather than to the player',
        () async {
      // Nothing is mounted yet, so LoadContent has to reach the app layer,
      // which navigates. A binding cannot serve it.
      final controller = RemoteTargetController();
      final seen = <RemoteControlIntent>[];
      controller.intents.listen(seen.add);

      controller.submit(const LoadContentIntent(
        mediaItemId: 'item-9',
        episodeId: null,
        startAt: Duration.zero,
        audioTrack: null,
        subtitleTrack: null,
        autoplay: true,
      ));
      await Future<void>.delayed(Duration.zero);

      expect(seen.single, isA<LoadContentIntent>());
    });

    test('drops transport intents once the player detaches', () async {
      final controller = RemoteTargetController();
      final binding = FakePlayerBinding();
      controller.attachPlayer(binding);
      controller.detachPlayer();

      controller.submit(const TransportIntent(TransportAction.play));
      await Future<void>.delayed(Duration.zero);

      expect(binding.calls, isEmpty);
      expect(controller.snapshot(), isNull);
    });
  });
}
