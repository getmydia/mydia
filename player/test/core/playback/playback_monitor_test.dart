import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/playback/frame_stats_sampler.dart';
import 'package:player/core/playback/health_sample.dart';
import 'package:player/core/playback/playback_monitor.dart';

class _Signals {
  final position = StreamController<Duration>.broadcast();
  final buffer = StreamController<Duration>.broadcast();
  final buffering = StreamController<bool>.broadcast();
  final playing = StreamController<bool>.broadcast();
  final error = StreamController<String>.broadcast();

  PlayerSignals get signals => PlayerSignals(
        position: position.stream,
        buffer: buffer.stream,
        buffering: buffering.stream,
        playing: playing.stream,
        error: error.stream,
      );
}

class _ScriptedSampler implements FrameStatsSampler {
  _ScriptedSampler(this.stats);

  final List<FrameStats?> stats;
  var calls = 0;

  @override
  Future<FrameStats?> sample() async {
    final index = calls < stats.length ? calls : stats.length - 1;
    calls++;
    return stats[index];
  }
}

void main() {
  test('emits one sample per interval from the latest signal values', () {
    fakeAsync((async) {
      final s = _Signals();
      final sampler = _ScriptedSampler([
        const FrameStats(droppedFrames: 10, throughputKbps: 8000),
        const FrameStats(droppedFrames: 14, throughputKbps: 9000),
      ]);
      final monitor = PlaybackMonitor(signals: s.signals, sampler: sampler);
      final seen = <HealthSample>[];
      monitor.samples.listen(seen.add);
      monitor.start();

      s.position.add(const Duration(seconds: 30));
      s.buffer.add(const Duration(seconds: 42));
      s.playing.add(true);
      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();

      expect(seen, hasLength(1));
      expect(seen.single.at, const Duration(seconds: 1));
      expect(seen.single.position, const Duration(seconds: 30));
      expect(seen.single.bufferedAhead, const Duration(seconds: 12));
      expect(seen.single.playing, isTrue);
      expect(seen.single.buffering, isFalse);
      // First sample has no previous cumulative count to diff against.
      expect(seen.single.droppedFrames, isNull);
      expect(seen.single.throughputKbps, 8000);

      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();
      expect(seen, hasLength(2));
      expect(seen.last.at, const Duration(seconds: 2));
      expect(seen.last.droppedFrames, 4);

      monitor.dispose();
    });
  });

  test('buffered ahead never goes negative', () {
    fakeAsync((async) {
      final s = _Signals();
      final monitor = PlaybackMonitor(
        signals: s.signals,
        sampler: const NoFrameStatsSampler(),
      );
      final seen = <HealthSample>[];
      monitor.samples.listen(seen.add);
      monitor.start();
      s.position.add(const Duration(seconds: 50));
      s.buffer.add(const Duration(seconds: 40));
      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();
      expect(seen.single.bufferedAhead, Duration.zero);
      expect(seen.single.droppedFrames, isNull);
      expect(seen.single.throughputKbps, isNull);
      monitor.dispose();
    });
  });

  test('an error is reported on the next sample only', () {
    fakeAsync((async) {
      final s = _Signals();
      final monitor = PlaybackMonitor(
        signals: s.signals,
        sampler: const NoFrameStatsSampler(),
      );
      final seen = <HealthSample>[];
      monitor.samples.listen(seen.add);
      monitor.start();
      s.error.add('Could not open codec.');
      async.elapse(const Duration(seconds: 2));
      async.flushMicrotasks();
      expect(seen.map((x) => x.fault), [true, false]);
      monitor.dispose();
    });
  });

  test('reset restarts the clock and the dropped-frame baseline', () {
    fakeAsync((async) {
      final s = _Signals();
      final sampler = _ScriptedSampler([
        const FrameStats(droppedFrames: 100),
        const FrameStats(droppedFrames: 105),
        const FrameStats(droppedFrames: 0),
        const FrameStats(droppedFrames: 3),
      ]);
      final monitor = PlaybackMonitor(signals: s.signals, sampler: sampler);
      final seen = <HealthSample>[];
      monitor.samples.listen(seen.add);
      monitor.start();
      async.elapse(const Duration(seconds: 2));
      async.flushMicrotasks();
      expect(seen.last.droppedFrames, 5);

      monitor.reset();
      async.elapse(const Duration(seconds: 2));
      async.flushMicrotasks();
      expect(seen, hasLength(4));
      expect(seen[2].at, const Duration(seconds: 1));
      expect(seen[2].droppedFrames, isNull);
      expect(seen[3].droppedFrames, 3);
      monitor.dispose();
    });
  });
}
