import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/cast/receiver_profile.dart';
import 'package:player/core/cast/source_cast_binding.dart';
import 'package:player/core/player/periodic_progress_reporter.dart';

class _RecordingReporter extends PeriodicProgressReporter {
  final progress = <(int, int, bool)>[];
  var watched = 0;
  final stops = <(int, int)>[];

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
      stops.add((positionSeconds, durationSeconds));
}

void main() {
  group('ReporterCastProgressSink', () {
    test('reports positions and marks watched once past the threshold',
        () async {
      final reporter = _RecordingReporter();
      final sink = ReporterCastProgressSink(reporter);
      const duration = Duration(minutes: 100);

      await sink.report(
          position: const Duration(minutes: 10),
          duration: duration,
          paused: false);
      await sink.report(
          position: const Duration(minutes: 95),
          duration: duration,
          paused: true);
      await sink.report(
          position: const Duration(minutes: 96),
          duration: duration,
          paused: false);

      expect(reporter.progress, [
        (600, 6000, false),
        (5700, 6000, true),
        (5760, 6000, false),
      ]);
      expect(reporter.watched, 1);
    });

    test('stopped reports the last position, once', () async {
      final reporter = _RecordingReporter();
      final sink = ReporterCastProgressSink(reporter);
      await sink.report(
          position: const Duration(seconds: 42),
          duration: const Duration(seconds: 600),
          paused: false);

      await sink.stopped();
      await sink.stopped();

      expect(reporter.stops, [(42, 600)]);
    });

    test('an unknown duration reports nothing', () async {
      final reporter = _RecordingReporter();
      await ReporterCastProgressSink(reporter).report(
          position: const Duration(seconds: 5),
          duration: Duration.zero,
          paused: false);
      expect(reporter.progress, isEmpty);
    });
  });

  test('the receiver copies H.264 only', () {
    expect(receiverCanCopyVideo('h264'), isTrue);
    expect(receiverCanCopyVideo('AVC'), isTrue);
    expect(receiverCanCopyVideo('hevc'), isFalse);
    expect(receiverCanCopyVideo(null), isFalse);
  });

  test('image subtitle codecs are recognized', () {
    expect(isImageSubtitleCodec('PGSSUB'), isTrue);
    expect(isImageSubtitleCodec('dvd_subtitle'), isTrue);
    expect(isImageSubtitleCodec('subrip'), isFalse);
    expect(isImageSubtitleCodec(null), isFalse);
  });
}
