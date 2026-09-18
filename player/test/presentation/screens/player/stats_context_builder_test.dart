import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:player/core/playback/playback_memory.dart';
import 'package:player/core/playback/playback_plan.dart';
import 'package:player/core/playback/stats/playback_stats.dart';
import 'package:player/domain/models/quality_rung.dart';
import 'package:player/presentation/screens/player/stats_context_builder.dart';

// PlaybackPlan's constructors require `reason` (DirectPlayPlan) and
// `strategy`/`rung`/`adaptive`/`reason` (HlsPlan); QualityRung exposes only
// `original` and `auto` as named constants, not a rung per height. Neither
// matches the brief's fixtures, so both are filled in here from the real
// signatures in playback_plan.dart and quality_rung.dart.
const _r1080 = QualityRung(label: '1080p', height: 1080, maxBitrateKbps: 8000);
const _r720 = QualityRung(label: '720p', height: 720, maxBitrateKbps: 4000);

void main() {
  test('a direct play plan reports direct, with no Why', () {
    final context = buildStatsContext(
      plan: const DirectPlayPlan(reason: PlanReason.directPlayAccepted),
      isDownloadedSource: false,
      selectedQuality: QualityRung.original,
      effectiveQuality: null,
      duration: const Duration(minutes: 90),
      lastFallback: null,
      knownFailures: const {},
      sourceHeight: 1080,
      sourceCodec: 'h264',
      sourceBitrateKbps: 8000,
      sourceContainer: 'mkv',
      videoTrack: null,
      audioTrack: null,
      linkLabel: 'direct p2p - 1 peer',
      linkHealthy: true,
    );

    expect(context.mode, PlaybackMode.direct);
    expect(context.why, isNull);
    expect(context.qualityLabel, 'Original');
  });

  // The single most asked support question is "why is my 4K file
  // transcoding". A remembered decode failure is the usual answer and the
  // player already knows it.
  test('a remembered decode failure explains an Auto transcode', () {
    final context = buildStatsContext(
      plan: const HlsPlan(
        strategy: HlsStrategy.transcode,
        rung: _r1080,
        adaptive: true,
        reason: PlanReason.shapeKnownToFail,
      ),
      isDownloadedSource: false,
      selectedQuality: QualityRung.auto,
      effectiveQuality: _r1080,
      duration: const Duration(minutes: 90),
      lastFallback: null,
      // Not `const`: FailureKey overrides `==`, so a const set literal
      // fails constant evaluation ("does not have a primitive equality").
      knownFailures: {
        const FailureKey(videoCodec: 'hevc', heightBucket: 2160),
      },
      sourceHeight: 2160,
      sourceCodec: 'hevc',
      sourceBitrateKbps: 14200,
      sourceContainer: 'mkv',
      videoTrack: null,
      audioTrack: null,
      linkLabel: 'direct p2p - 1 peer',
      linkHealthy: true,
    );

    expect(context.mode, PlaybackMode.transcode);
    expect(context.why, contains('hevc'));
    expect(context.sourceLabel, '2160p hevc - 14.2 Mb/s - mkv');
  });

  // A fallback that actually happened outranks anything inferred from the
  // plan: it is the more specific answer and it has a raw detail worth
  // carrying to the clipboard.
  test('a fallback this session wins over the plan-derived reason', () {
    final context = buildStatsContext(
      plan: const HlsPlan(
        strategy: HlsStrategy.transcode,
        rung: _r720,
        adaptive: true,
        reason: PlanReason.bitrateExceedsThroughput,
      ),
      isDownloadedSource: false,
      selectedQuality: QualityRung.auto,
      effectiveQuality: _r720,
      duration: const Duration(minutes: 90),
      lastFallback: const StatsFallback(
        reason: FailureReason.bandwidth,
        detail: 'bandwidth: buffer drained for 4 samples',
      ),
      knownFailures: const {},
      sourceHeight: 2160,
      sourceCodec: 'hevc',
      sourceBitrateKbps: 14200,
      sourceContainer: 'mkv',
      videoTrack: null,
      audioTrack: null,
      linkLabel: 'relayed - 1 peer',
      linkHealthy: false,
    );

    expect(context.why, fallbackMessageFor(FailureReason.bandwidth));
    expect(
      context.whyDetail,
      'bandwidth: buffer drained for 4 samples',
    );
  });

  test('a stream copy says the container is not playable directly', () {
    final context = buildStatsContext(
      plan: const HlsPlan(
        strategy: HlsStrategy.copy,
        rung: QualityRung.original,
        adaptive: false,
        reason: PlanReason.copyAccepted,
      ),
      isDownloadedSource: false,
      selectedQuality: QualityRung.original,
      effectiveQuality: null,
      duration: const Duration(minutes: 90),
      lastFallback: null,
      knownFailures: const {},
      sourceHeight: 1080,
      sourceCodec: 'h264',
      sourceBitrateKbps: 8000,
      sourceContainer: 'mkv',
      videoTrack: null,
      audioTrack: null,
      linkLabel: 'direct p2p - 1 peer',
      linkHealthy: true,
    );

    expect(context.mode, PlaybackMode.copy);
    // Sentence case, matching every other Why message ("Quality capped
    // to...", "Remembered decode failure on...").
    expect(context.why, contains('Container'));
  });

  test('a fixed rung says the quality was capped on purpose', () {
    final context = buildStatsContext(
      plan: const HlsPlan(
        strategy: HlsStrategy.transcode,
        rung: _r720,
        adaptive: false,
        reason: PlanReason.fixedRungRequested,
      ),
      isDownloadedSource: false,
      selectedQuality: _r720,
      effectiveQuality: _r720,
      duration: const Duration(minutes: 90),
      lastFallback: null,
      knownFailures: const {},
      sourceHeight: 2160,
      sourceCodec: 'hevc',
      sourceBitrateKbps: 14200,
      sourceContainer: 'mkv',
      videoTrack: null,
      audioTrack: null,
      linkLabel: 'direct p2p - 1 peer',
      linkHealthy: true,
    );

    expect(context.why, contains('capped'));
  });

  // A downloaded file has no server, so no link and no throughput. It is
  // not a degraded server source and must not read as one.
  test('a downloaded file reports localFile and no link', () {
    final context = buildStatsContext(
      plan: null,
      isDownloadedSource: true,
      selectedQuality: QualityRung.original,
      effectiveQuality: null,
      duration: const Duration(minutes: 90),
      lastFallback: null,
      knownFailures: const {},
      sourceHeight: null,
      sourceCodec: null,
      sourceBitrateKbps: null,
      sourceContainer: null,
      videoTrack: null,
      audioTrack: null,
      linkLabel: null,
      linkHealthy: true,
    );

    expect(context.mode, PlaybackMode.localFile);
    expect(context.linkLabel, isNull);
    expect(context.sourceLabel, isNull);
    expect(context.why, isNull);
  });

  test('a video track becomes the Video and Decoder rows', () {
    final context = buildStatsContext(
      plan: const DirectPlayPlan(reason: PlanReason.directPlayAccepted),
      isDownloadedSource: false,
      selectedQuality: QualityRung.original,
      effectiveQuality: null,
      duration: const Duration(minutes: 90),
      lastFallback: null,
      knownFailures: const {},
      sourceHeight: 1080,
      sourceCodec: 'h264',
      sourceBitrateKbps: 8000,
      sourceContainer: 'mkv',
      videoTrack: const VideoTrack(
        '1',
        'Video',
        'und',
        codec: 'h264',
        decoder: 'h264 (vaapi)',
        w: 1920,
        h: 1080,
        fps: 23.976,
      ),
      audioTrack: const AudioTrack(
        '2',
        'Audio',
        'eng',
        codec: 'eac3',
        channels: '5.1',
        samplerate: 48000,
      ),
      linkLabel: 'direct p2p - 1 peer',
      linkHealthy: true,
    );

    expect(context.videoLabel, '1920x1080 h264 - 23.976 fps');
    expect(context.decoderLabel, 'h264 (vaapi)');
    expect(context.hardwareDecode, isTrue);
    expect(context.audioLabel, 'eac3 5.1 - 48 kHz - eng');
  });

  test('a software decoder reads as software', () {
    final context = buildStatsContext(
      plan: const DirectPlayPlan(reason: PlanReason.directPlayAccepted),
      isDownloadedSource: false,
      selectedQuality: QualityRung.original,
      effectiveQuality: null,
      duration: const Duration(minutes: 90),
      lastFallback: null,
      knownFailures: const {},
      sourceHeight: 1080,
      sourceCodec: 'h264',
      sourceBitrateKbps: 8000,
      sourceContainer: 'mkv',
      videoTrack: const VideoTrack(
        '1',
        'Video',
        'und',
        codec: 'h264',
        decoder: 'h264',
        w: 1920,
        h: 1080,
        fps: 23.976,
      ),
      audioTrack: null,
      linkLabel: 'direct p2p - 1 peer',
      linkHealthy: true,
    );

    expect(context.hardwareDecode, isFalse);
  });
}
