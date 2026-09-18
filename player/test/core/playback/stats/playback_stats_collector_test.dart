import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/playback/frame_stats_sampler.dart';
import 'package:player/core/playback/health_sample.dart';
import 'package:player/core/playback/playback_monitor.dart';
import 'package:player/core/playback/stats/playback_stats_collector.dart';

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
  test('the first sample has a total but no delta', () {
    fakeAsync((async) {
      final s = _Signals();
      final collector = PlaybackStatsCollector(
        signals: s.signals,
        sampler: _ScriptedSampler([
          const FrameStats(droppedFrames: 10, throughputKbps: 8000),
          const FrameStats(droppedFrames: 14, throughputKbps: 9000),
        ]),
      );
      addTearDown(collector.dispose);
      collector.start();

      s.position.add(const Duration(seconds: 30));
      s.buffer.add(const Duration(seconds: 42));
      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();

      final first = collector.samples.value!;
      expect(first.droppedFrames, isNull);
      expect(first.droppedFramesTotal, 10);
      expect(first.bufferedAhead, const Duration(seconds: 12));
      expect(first.position, const Duration(seconds: 30));
      expect(first.throughputKbps, 8000);

      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();

      final second = collector.samples.value!;
      expect(second.droppedFrames, 4);
      expect(second.droppedFramesTotal, 14);
    });
  });

  test('a negative buffer reads as zero, never as a negative number', () {
    fakeAsync((async) {
      final s = _Signals();
      final collector = PlaybackStatsCollector(
        signals: s.signals,
        sampler: _ScriptedSampler([const FrameStats(droppedFrames: 0)]),
      );
      addTearDown(collector.dispose);
      collector.start();

      s.position.add(const Duration(seconds: 30));
      s.buffer.add(const Duration(seconds: 20));
      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();

      expect(collector.samples.value!.bufferedAhead, Duration.zero);
    });
  });

  // A frozen number is worse than an absent one: the viewer reads it as
  // current. After the grace window the row drops out instead.
  test('throughput goes stale after five unreadable seconds', () {
    fakeAsync((async) {
      final s = _Signals();
      final collector = PlaybackStatsCollector(
        signals: s.signals,
        sampler: _ScriptedSampler([
          const FrameStats(droppedFrames: 0, throughputKbps: 6000),
          null,
        ]),
      );
      addTearDown(collector.dispose);
      collector.start();

      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();
      expect(collector.samples.value!.throughputKbps, 6000);

      // Four more unreadable seconds: still inside the window.
      async.elapse(const Duration(seconds: 4));
      async.flushMicrotasks();
      expect(collector.samples.value!.throughputKbps, 6000);

      async.elapse(const Duration(seconds: 2));
      async.flushMicrotasks();
      expect(collector.samples.value!.throughputKbps, isNull);
    });
  });

  // Carrying a previous source's cumulative count into a new one reports a
  // spike of thousands of dropped frames that never happened.
  test('rebind clears the baseline and the history', () {
    fakeAsync((async) {
      final s = _Signals();
      final collector = PlaybackStatsCollector(
        signals: s.signals,
        sampler: _ScriptedSampler([
          const FrameStats(droppedFrames: 900),
          const FrameStats(droppedFrames: 901),
          const FrameStats(droppedFrames: 4),
        ]),
      );
      addTearDown(collector.dispose);
      collector.start();

      async.elapse(const Duration(seconds: 2));
      async.flushMicrotasks();
      expect(collector.samples.value!.droppedFrames, 1);
      expect(collector.samples.value!.history, isNotEmpty);

      collector.rebind();
      expect(collector.samples.value, isNull);

      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();
      expect(collector.samples.value!.droppedFrames, isNull);
      expect(collector.samples.value!.droppedFramesTotal, 4);
      expect(collector.samples.value!.history, hasLength(1));
    });
  });

  test('the history caps at sixty points, oldest dropped first', () {
    fakeAsync((async) {
      final s = _Signals();
      final collector = PlaybackStatsCollector(
        signals: s.signals,
        sampler: _ScriptedSampler([
          const FrameStats(droppedFrames: 0, throughputKbps: 5000),
        ]),
      );
      addTearDown(collector.dispose);
      collector.start();

      s.buffer.add(const Duration(seconds: 9));
      async.elapse(const Duration(seconds: 90));
      async.flushMicrotasks();

      final history = collector.samples.value!.history;
      expect(history, hasLength(PlaybackStatsCollector.historyLength));
      expect(history.last.throughputKbps, 5000);
      expect(history.last.bufferedMs, 9000);
    });
  });

  test('disposal stops the timer', () {
    fakeAsync((async) {
      final s = _Signals();
      final sampler = _ScriptedSampler([const FrameStats(droppedFrames: 0)]);
      final collector = PlaybackStatsCollector(
        signals: s.signals,
        sampler: sampler,
      );
      collector.start();

      async.elapse(const Duration(seconds: 2));
      async.flushMicrotasks();
      final calls = sampler.calls;

      collector.dispose();
      async.elapse(const Duration(seconds: 5));
      async.flushMicrotasks();

      expect(sampler.calls, calls);
    });
  });
}
