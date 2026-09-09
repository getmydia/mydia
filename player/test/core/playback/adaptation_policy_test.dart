import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/playback/adaptation_policy.dart';
import 'package:player/core/playback/adaptation_thresholds.dart';
import 'package:player/core/playback/health_sample.dart';
import 'package:player/core/playback/playback_memory.dart';

/// Builds one sample per second from a small script. Position advances by a
/// second while playing and not buffering.
class _Script {
  _Script();

  var _t = 0;
  var _pos = 0;

  HealthSample next({
    bool playing = true,
    bool buffering = false,
    int aheadMs = 30000,
    int? dropped = 0,
    int? kbps,
    bool fault = false,
  }) {
    _t++;
    if (playing && !buffering) _pos++;
    return HealthSample(
      at: Duration(seconds: _t),
      position: Duration(seconds: _pos),
      bufferedAhead: Duration(milliseconds: aheadMs),
      buffering: buffering,
      playing: playing,
      droppedFrames: dropped,
      throughputKbps: kbps,
      fault: fault,
    );
  }
}

AdaptationAction _drive(
  AdaptationPolicy policy,
  Iterable<HealthSample> samples,
) {
  AdaptationAction last = const NoAction();
  for (final sample in samples) {
    last = policy.observe(sample);
    if (last is! NoAction) return last;
  }
  return last;
}

void main() {
  group('verification', () {
    test('a fault before the first advance falls back as decodeFailed', () {
      final policy = AdaptationPolicy(source: SourceKind.direct);
      final s = _Script();
      final action = policy.observe(s.next(playing: false, fault: true));
      expect(action, isA<FallbackToTranscode>());
      expect(
        (action as FallbackToTranscode).reason,
        FailureReason.decodeFailed,
      );
      expect(policy.done, isTrue);
    });

    test('a fault after playback advanced is ignored', () {
      final policy = AdaptationPolicy(source: SourceKind.direct);
      final s = _Script();
      policy.observe(s.next());
      policy.observe(s.next());
      expect(policy.observe(s.next(fault: true)), isA<NoAction>());
    });

    test('more than one dropped frame per second over 10 s is decodeTooSlow',
        () {
      final policy = AdaptationPolicy(source: SourceKind.direct);
      final s = _Script();
      // 10 samples of 1 drop each: exactly 10 over 10 s, not over.
      expect(
        _drive(policy, List.generate(10, (_) => s.next(dropped: 1))),
        isA<NoAction>(),
      );
      // One more sample with 2 drops: window is now 11 over 10 s.
      final action = policy.observe(s.next(dropped: 2));
      expect(action, isA<FallbackToTranscode>());
      expect(
        (action as FallbackToTranscode).reason,
        FailureReason.decodeTooSlow,
      );
    });

    test('unknown dropped frames never count', () {
      final policy = AdaptationPolicy(source: SourceKind.direct);
      final s = _Script();
      expect(
        _drive(policy, List.generate(20, (_) => s.next(dropped: null))),
        isA<NoAction>(),
      );
    });

    test('two stalls during verification are bandwidth', () {
      final policy = AdaptationPolicy(source: SourceKind.copy);
      final s = _Script();
      final samples = [
        s.next(),
        s.next(buffering: true, kbps: 3000),
        s.next(buffering: true, kbps: 3000), // same stall
        s.next(),
        s.next(buffering: true, kbps: 3100),
      ];
      final action = _drive(policy, samples);
      expect(action, isA<FallbackToTranscode>());
      expect((action as FallbackToTranscode).reason, FailureReason.bandwidth);
      expect(action.throughputKbps, 3100);
    });

    test('a single stall is tolerated', () {
      final policy = AdaptationPolicy(source: SourceKind.direct);
      final s = _Script();
      expect(
        _drive(policy, [s.next(), s.next(buffering: true), s.next(), s.next()]),
        isA<NoAction>(),
      );
    });

    test('15 draining samples under 10 s is bandwidth; 14 is not', () {
      final policy = AdaptationPolicy(source: SourceKind.direct);
      final s = _Script();
      // The first sample only sets the baseline; a decrease needs a previous.
      policy.observe(s.next(aheadMs: 9000));
      // 8.5 s down to 2.0 s in 500 ms steps: 14 consecutive decreases.
      final draining =
          List.generate(14, (i) => s.next(aheadMs: 8500 - 500 * i));
      expect(_drive(policy, draining), isA<NoAction>());
      // The 15th decrease.
      final action = policy.observe(s.next(aheadMs: 1000));
      expect(action, isA<FallbackToTranscode>());
      expect((action as FallbackToTranscode).reason, FailureReason.bandwidth);
    });

    test('a drain above 10 s ahead does not count', () {
      final policy = AdaptationPolicy(source: SourceKind.direct);
      final s = _Script();
      // 40 s down to 21 s: shrinking, but never under the 10 s floor.
      final draining =
          List.generate(20, (i) => s.next(aheadMs: 40000 - 1000 * i));
      expect(_drive(policy, draining), isA<NoAction>());
    });

    test('a flat or growing buffer resets the drain run', () {
      final policy = AdaptationPolicy(source: SourceKind.direct);
      final s = _Script();
      policy.observe(s.next(aheadMs: 9000));
      _drive(policy, List.generate(10, (i) => s.next(aheadMs: 8500 - 500 * i)));
      policy.observe(s.next(aheadMs: 4000)); // equal to the previous: reset
      final draining =
          List.generate(14, (i) => s.next(aheadMs: 3900 - 100 * i));
      expect(_drive(policy, draining), isA<NoAction>());
    });

    test('verification ends after 20 s of playing time', () {
      final policy = AdaptationPolicy(source: SourceKind.direct);
      final s = _Script();
      expect(policy.verifying, isTrue);
      _drive(policy, List.generate(19, (_) => s.next()));
      expect(policy.verifying, isTrue);
      // Paused samples do not count as playing time.
      _drive(policy, List.generate(5, (_) => s.next(playing: false)));
      expect(policy.verifying, isTrue);
      policy.observe(s.next());
      expect(policy.verifying, isFalse);
    });
  });

  group('after verification', () {
    List<HealthSample> warm(_Script s) => List.generate(20, (_) => s.next());

    test('three stalls within 120 s fall back on a direct source', () {
      final policy = AdaptationPolicy(source: SourceKind.direct);
      final s = _Script();
      _drive(policy, warm(s));
      final samples = [
        s.next(buffering: true),
        ...List.generate(30, (_) => s.next()),
        s.next(buffering: true),
        ...List.generate(30, (_) => s.next()),
        s.next(buffering: true),
      ];
      final action = _drive(policy, samples);
      expect(action, isA<FallbackToTranscode>());
      expect((action as FallbackToTranscode).reason, FailureReason.bandwidth);
    });

    test('two stalls after verification are tolerated', () {
      final policy = AdaptationPolicy(source: SourceKind.direct);
      final s = _Script();
      _drive(policy, warm(s));
      final samples = [
        s.next(buffering: true),
        ...List.generate(30, (_) => s.next()),
        s.next(buffering: true),
        ...List.generate(30, (_) => s.next()),
      ];
      expect(_drive(policy, samples), isA<NoAction>());
    });

    test('a stall older than 120 s no longer counts', () {
      final policy = AdaptationPolicy(source: SourceKind.direct);
      final s = _Script();
      _drive(policy, warm(s));
      final samples = [
        s.next(buffering: true),
        ...List.generate(125, (_) => s.next()),
        s.next(buffering: true),
        ...List.generate(5, (_) => s.next()),
        s.next(buffering: true),
      ];
      expect(_drive(policy, samples), isA<NoAction>());
    });

    test('drops must be sustained across three 10 s windows', () {
      final policy = AdaptationPolicy(source: SourceKind.copy);
      final s = _Script();
      _drive(policy, warm(s));
      // Two heavy windows then a clean one: not sustained.
      expect(
        _drive(policy, [
          ...List.generate(20, (_) => s.next(dropped: 2)),
          ...List.generate(10, (_) => s.next(dropped: 0)),
        ]),
        isA<NoAction>(),
      );
      // Three heavy windows in a row.
      final action =
          _drive(policy, List.generate(30, (_) => s.next(dropped: 2)));
      expect(action, isA<FallbackToTranscode>());
      expect(
        (action as FallbackToTranscode).reason,
        FailureReason.decodeTooSlow,
      );
    });

    test('a transcode source never emits an action in this phase', () {
      final policy = AdaptationPolicy(source: SourceKind.transcode);
      final s = _Script();
      final samples = [
        s.next(fault: true, playing: false),
        ...List.generate(30, (_) => s.next(dropped: 5, buffering: true)),
      ];
      expect(_drive(policy, samples), isA<NoAction>());
    });
  });

  test('after an action the policy is done and stays silent', () {
    final policy = AdaptationPolicy(source: SourceKind.direct);
    final s = _Script();
    policy.observe(s.next(playing: false, fault: true));
    expect(policy.done, isTrue);
    expect(
        policy.observe(s.next(playing: false, fault: true)), isA<NoAction>());
  });

  test('thresholds are injectable', () {
    final policy = AdaptationPolicy(
      source: SourceKind.direct,
      thresholds: const AdaptationThresholds(verificationStalls: 1),
    );
    final s = _Script();
    expect(
      _drive(policy, [s.next(), s.next(buffering: true)]),
      isA<FallbackToTranscode>(),
    );
  });
}
