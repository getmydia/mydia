import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:player/core/player/periodic_progress_reporter.dart';

class _StaticPlatformPlayer extends PlatformPlayer {
  _StaticPlatformPlayer() : super(configuration: const PlayerConfiguration());
  final _handle = Completer<int>();
  @override
  Future<int> get handle => _handle.future;

  void emit(Duration p) => positionController.add(p);

  void at(Duration position, {bool playing = true}) {
    state = state.copyWith(
      position: position,
      duration: const Duration(minutes: 100),
      playing: playing,
    );
  }
}

class _Recorder extends PeriodicProgressReporter {
  final progress = <(int, int, bool)>[];
  int watched = 0;
  final stopped = <int>[];

  @override
  Future<void> sendProgress({
    required int positionSeconds,
    required int durationSeconds,
    required bool paused,
  }) async =>
      progress.add((positionSeconds, durationSeconds, paused));

  @override
  Future<void> sendWatched() async => watched++;

  @override
  Future<void> sendStopped({
    required int positionSeconds,
    required int durationSeconds,
  }) async =>
      stopped.add(positionSeconds);
}

void main() {
  test('reports position, crosses watched once, stops at the last position',
      () async {
    final platform = _StaticPlatformPlayer()..at(const Duration(minutes: 10));
    final player = Player(platformPlayer: platform);
    final reporter = _Recorder();

    await reporter.save(player, mediaType: 'movie', mediaId: 'x');
    expect(reporter.progress.single, (600, 6000, false));
    expect(reporter.watched, 0);

    platform.at(const Duration(minutes: 95), playing: false);
    await reporter.save(player, mediaType: 'movie', mediaId: 'x');
    await reporter.save(player, mediaType: 'movie', mediaId: 'x');
    expect(reporter.progress.last.$3, isTrue, reason: 'paused');
    expect(reporter.watched, 1);

    reporter.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(reporter.stopped, [5700]);
  });

  test('reports on a seek jump, not on ordinary playback steps', () async {
    final platform = _StaticPlatformPlayer()..at(const Duration(minutes: 10));
    final player = Player(platformPlayer: platform);
    final reporter = _Recorder()
      ..start(player, mediaType: 'movie', mediaId: 'x');

    platform.emit(const Duration(minutes: 10));
    await Future<void>.delayed(Duration.zero);
    platform.at(const Duration(minutes: 10, seconds: 1));
    platform.emit(const Duration(minutes: 10, seconds: 1));
    await Future<void>.delayed(Duration.zero);
    expect(reporter.progress, isEmpty);

    platform.at(const Duration(minutes: 11, seconds: 1));
    platform.emit(const Duration(minutes: 11, seconds: 1));
    await Future<void>.delayed(Duration.zero);
    expect(reporter.progress.single.$1, 661);

    reporter.dispose();
  });

  test('sends nothing after dispose', () async {
    final platform = _StaticPlatformPlayer()..at(const Duration(minutes: 95));
    final player = Player(platformPlayer: platform);
    final reporter = _Recorder();
    await reporter.save(player, mediaType: 'movie', mediaId: 'x');
    reporter.dispose();
    await reporter.save(player, mediaType: 'movie', mediaId: 'x');
    expect(reporter.progress, hasLength(1));
    expect(reporter.watched, 1);
  });
}
