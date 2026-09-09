import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/playback/playback_memory.dart';
import 'package:player/core/playback/playback_plan.dart';
import 'package:player/core/playback/playback_planner.dart';
import 'package:player/domain/models/quality_rung.dart';

const _hevc = 'hvc1.2.4.L120.B0';
const _h264 = 'avc1.640028';

const _directPlayList = [
  CandidateStrategy(
    strategy: 'DIRECT_PLAY',
    mime: 'video/mp4; codecs="$_hevc, mp4a.40.2"',
    videoCodec: _hevc,
  ),
  CandidateStrategy(strategy: 'TRANSCODE', mime: 'video/mp2t'),
];

const _remuxList = [
  CandidateStrategy(
    strategy: 'REMUX',
    mime: 'video/mp4; codecs="$_h264, mp4a.40.2"',
    videoCodec: _h264,
  ),
  CandidateStrategy(
    strategy: 'HLS_COPY',
    mime: 'video/mp2t; codecs="$_h264, mp4a.40.2"',
    videoCodec: _h264,
  ),
  CandidateStrategy(strategy: 'TRANSCODE', mime: 'video/mp2t'),
];

/// The :needs_transcoding shape an old server emits: HLS_COPY leads.
const _leadingCopyList = [
  CandidateStrategy(
    strategy: 'HLS_COPY',
    mime: 'video/mp2t; codecs="$_hevc, mp4a.40.2"',
    videoCodec: _hevc,
  ),
  CandidateStrategy(strategy: 'TRANSCODE', mime: 'video/mp2t'),
];

const _transcodeOnly = [
  CandidateStrategy(strategy: 'TRANSCODE', mime: 'video/mp2t'),
];

bool _accept(String _) => true;
bool _reject(String _) => false;

PlanInputs _inputs({
  List<CandidateStrategy> candidates = _directPlayList,
  bool isWeb = false,
  bool Function(String) typeSupported = _accept,
  QualityChoice choice = QualityChoice.original,
  int? sourceHeight = 1080,
  int? fileBitrateKbps,
  int? knownThroughputKbps,
  Set<FailureKey> knownFailures = const {},
}) =>
    PlanInputs(
      candidates: candidates,
      isWeb: isWeb,
      typeSupported: typeSupported,
      choice: choice,
      sourceHeight: sourceHeight,
      fileBitrateKbps: fileBitrateKbps,
      knownThroughputKbps: knownThroughputKbps,
      knownFailures: knownFailures,
    );

void main() {
  group('rule 1, direct play', () {
    test('native, leading DIRECT_PLAY, Original: direct play', () {
      final plan = planPlayback(_inputs());
      expect(plan, isA<DirectPlayPlan>());
      expect(plan.reason, PlanReason.directPlayAccepted);
    });

    test('a leading REMUX also direct plays', () {
      expect(
          planPlayback(_inputs(candidates: _remuxList)), isA<DirectPlayPlan>());
    });

    test('Auto direct plays too', () {
      expect(
        planPlayback(_inputs(choice: QualityChoice.auto)),
        isA<DirectPlayPlan>(),
      );
    });

    test('web never direct plays', () {
      final plan = planPlayback(_inputs(isWeb: true));
      expect(plan, isA<HlsPlan>());
      expect(plan.reason, PlanReason.webNeverDirectPlays);
    });

    test('a shape known to fail goes to transcode', () {
      final plan = planPlayback(_inputs(
        choice: QualityChoice.auto,
        knownFailures: {
          const FailureKey(videoCodec: _hevc, heightBucket: 1080),
        },
      ));
      expect(plan, isA<HlsPlan>());
      expect((plan as HlsPlan).strategy, HlsStrategy.transcode);
      expect(plan.reason, PlanReason.shapeKnownToFail);
    });

    test('Original ignores a known failure and attempts direct play', () {
      final plan = planPlayback(_inputs(knownFailures: {
        const FailureKey(videoCodec: _hevc, heightBucket: 1080),
      }));
      expect(plan, isA<DirectPlayPlan>());
      expect(plan.reason, PlanReason.directPlayAccepted);
    });

    test('a bitrate that does not fit throughput with headroom transcodes', () {
      // 20000 * 1.3 = 26000 > 25000
      final plan = planPlayback(
        _inputs(fileBitrateKbps: 20000, knownThroughputKbps: 25000),
      );
      expect(plan.reason, PlanReason.bitrateExceedsThroughput);
      expect((plan as HlsPlan).strategy, HlsStrategy.transcode);
    });

    test('a bitrate that fits, or an unknown one, direct plays', () {
      expect(
        planPlayback(
          _inputs(fileBitrateKbps: 19000, knownThroughputKbps: 25000),
        ),
        isA<DirectPlayPlan>(),
      );
      expect(
        planPlayback(_inputs(fileBitrateKbps: null, knownThroughputKbps: 1)),
        isA<DirectPlayPlan>(),
      );
      expect(
          planPlayback(_inputs(fileBitrateKbps: 99999)), isA<DirectPlayPlan>());
    });
  });

  group('rule 2, copy', () {
    test('web takes a non-leading HLS_COPY the browser accepts', () {
      final plan = planPlayback(_inputs(candidates: _remuxList, isWeb: true));
      expect(plan, isA<HlsPlan>());
      expect((plan as HlsPlan).strategy, HlsStrategy.copy);
      expect(plan.rung, QualityRung.original);
      expect(plan.reason, PlanReason.copyAccepted);
    });

    test('web rejects a copy whose MIME the browser refuses', () {
      final plan = planPlayback(
        _inputs(candidates: _remuxList, isWeb: true, typeSupported: _reject),
      );
      expect((plan as HlsPlan).strategy, HlsStrategy.transcode);
      expect(plan.reason, PlanReason.copyRejectedByMime);
    });

    test('native never consults the MIME check', () {
      // Direct play is blocked by memory; copy is then offered without
      // asking typeSupported, which rejects everything here.
      final plan = planPlayback(_inputs(
        candidates: _remuxList,
        choice: QualityChoice.auto,
        typeSupported: _reject,
        knownFailures: {
          const FailureKey(videoCodec: _h264, heightBucket: 1080),
        },
      ));
      // The same shape failed to decode, so copy is refused for the same
      // reason, and the reason names the memory rather than the MIME.
      expect((plan as HlsPlan).strategy, HlsStrategy.transcode);
      expect(plan.reason, PlanReason.shapeKnownToFail);
    });

    test('Original ignores a known failure and attempts copy', () {
      final plan = planPlayback(_inputs(
        candidates: _remuxList,
        isWeb: true,
        knownFailures: {
          const FailureKey(videoCodec: _h264, heightBucket: 1080),
        },
      ));
      expect((plan as HlsPlan).strategy, HlsStrategy.copy);
      expect(plan.reason, PlanReason.copyAccepted);
    });

    test('a leading HLS_COPY is the needs_transcoding verdict, never taken',
        () {
      final plan = planPlayback(_inputs(candidates: _leadingCopyList));
      expect((plan as HlsPlan).strategy, HlsStrategy.transcode);
      // No DIRECT_PLAY or REMUX led the list, and the only HLS_COPY was the
      // leading one, so the structural blocker is what gets reported.
      expect(plan.reason, PlanReason.noDirectPlayCandidate);
    });

    test('a genuine copy refused for another reason names that reason', () {
      final plan = planPlayback(_inputs(
        candidates: _remuxList,
        isWeb: true,
        typeSupported: _reject,
      ));
      expect(plan.reason, PlanReason.copyRejectedByMime);
    });

    test('a bandwidth blocker also blocks copy, which carries the same bytes',
        () {
      final plan = planPlayback(_inputs(
        candidates: _remuxList,
        fileBitrateKbps: 20000,
        knownThroughputKbps: 20000,
      ));
      expect((plan as HlsPlan).strategy, HlsStrategy.transcode);
      expect(plan.reason, PlanReason.bitrateExceedsThroughput);
    });
  });

  group('rule 3, transcode', () {
    test('a fixed rung always transcodes at that rung, unadaptive', () {
      const rung = QualityRung(
        label: '480p',
        height: 480,
        maxBitrateKbps: 1500,
      );
      final plan = planPlayback(
        _inputs(choice: const QualityChoice.fixed(rung)),
      );
      expect(plan, isA<HlsPlan>());
      expect((plan as HlsPlan).strategy, HlsStrategy.transcode);
      expect(plan.rung, rung);
      expect(plan.adaptive, isFalse);
      expect(plan.reason, PlanReason.fixedRungRequested);
    });

    test('Original under transcode sends no caps', () {
      final plan = planPlayback(_inputs(candidates: _transcodeOnly));
      expect((plan as HlsPlan).rung, QualityRung.original);
      expect(plan.adaptive, isFalse);
    });

    test('Auto under transcode starts at the top of the adaptive ladder', () {
      final plan = planPlayback(
        _inputs(candidates: _transcodeOnly, choice: QualityChoice.auto),
      );
      expect((plan as HlsPlan).rung.label, '1080p');
      expect(plan.adaptive, isTrue);
    });

    test('Auto with known throughput starts at the highest rung that fits', () {
      // 4000 * 1.3 = 5200 <= 6000; 8000 * 1.3 = 10400 > 6000.
      final plan = planPlayback(_inputs(
        candidates: _transcodeOnly,
        choice: QualityChoice.auto,
        knownThroughputKbps: 6000,
      ));
      expect((plan as HlsPlan).rung.label, '720p');
    });

    test('an empty candidate list transcodes at Original', () {
      final plan = planPlayback(_inputs(candidates: const []));
      expect((plan as HlsPlan).strategy, HlsStrategy.transcode);
      expect(plan.rung, QualityRung.original);
      expect(plan.reason, PlanReason.noDirectPlayCandidate);
    });
  });

  group('startingRung', () {
    final ladder = deriveAdaptiveLadder(sourceHeight: 1080);

    test('unknown throughput picks the top', () {
      expect(startingRung(ladder, null).label, '1080p');
    });

    test('nothing fits picks the bottom', () {
      expect(startingRung(ladder, 100).label, '360p');
    });

    test('an empty ladder is Original', () {
      expect(startingRung(const [], 5000), QualityRung.original);
    });
  });

  group('fallbackPlan', () {
    test('unknown throughput lands one below the top', () {
      final plan = fallbackPlan(sourceHeight: 1080, throughputKbps: null);
      expect(plan.strategy, HlsStrategy.transcode);
      expect(plan.rung.label, '720p');
      expect(plan.adaptive, isTrue);
      expect(plan.reason, PlanReason.fallbackFromFailure);
    });

    test('a one-rung ladder lands on that rung', () {
      expect(
        fallbackPlan(sourceHeight: 400, throughputKbps: null).rung.label,
        '360p',
      );
    });

    test('known throughput uses the same rule as starting', () {
      expect(
        fallbackPlan(sourceHeight: 1080, throughputKbps: 6000).rung.label,
        '720p',
      );
    });

    test('a source below every rung falls back to Original', () {
      expect(
        fallbackPlan(sourceHeight: 200, throughputKbps: null).rung,
        QualityRung.original,
      );
    });
  });
}
