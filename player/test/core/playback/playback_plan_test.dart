import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/playback/playback_plan.dart';
import 'package:player/domain/models/quality_rung.dart';

void main() {
  group('QualityChoice', () {
    test('fromRung maps Original to original and others to fixed', () {
      expect(
          QualityChoice.fromRung(QualityRung.original), QualityChoice.original);
      const rung =
          QualityRung(label: '720p', height: 720, maxBitrateKbps: 4000);
      final choice = QualityChoice.fromRung(rung);
      expect(choice.kind, QualityChoiceKind.fixed);
      expect(choice.rung, rung);
    });

    test('only a fixed rung refuses lossless delivery', () {
      expect(QualityChoice.auto.allowsLossless, isTrue);
      expect(QualityChoice.original.allowsLossless, isTrue);
      expect(
        const QualityChoice.fixed(
          QualityRung(label: '480p', height: 480, maxBitrateKbps: 1500),
        ).allowsLossless,
        isFalse,
      );
    });
  });

  group('FileShape.fromCandidates', () {
    test('takes the leading candidate video codec and buckets the height', () {
      final shape = FileShape.fromCandidates(
        const [
          CandidateStrategy(
            strategy: 'DIRECT_PLAY',
            mime: 'video/mp4; codecs="hvc1.2.4.L120.B0, mp4a.40.2"',
            videoCodec: 'hvc1.2.4.L120.B0',
          ),
        ],
        sourceHeight: 1080,
      );
      expect(shape.videoCodec, 'hvc1.2.4.L120.B0');
      expect(shape.heightBucket, 1080);
    });

    test('an empty list or a null codec reads as unknown', () {
      expect(
        FileShape.fromCandidates(const [], sourceHeight: null).videoCodec,
        'unknown',
      );
      expect(
        FileShape.fromCandidates(
          const [CandidateStrategy(strategy: 'TRANSCODE', mime: 'video/mp2t')],
          sourceHeight: 720,
        ).videoCodec,
        'unknown',
      );
    });

    test('buckets are the smallest of 480/720/1080/2160 at or above', () {
      expect(FileShape.bucketHeight(360), 480);
      expect(FileShape.bucketHeight(480), 480);
      expect(FileShape.bucketHeight(576), 720);
      expect(FileShape.bucketHeight(1080), 1080);
      expect(FileShape.bucketHeight(1440), 2160);
      expect(FileShape.bucketHeight(4320), 2160);
      expect(FileShape.bucketHeight(null), 0);
    });
  });

  group('PlaybackPlan', () {
    test('describes itself for the decision log line', () {
      const plan = HlsPlan(
        strategy: HlsStrategy.transcode,
        rung: QualityRung(label: '720p', height: 720, maxBitrateKbps: 4000),
        adaptive: true,
        reason: PlanReason.noCopyCandidate,
      );
      expect(plan.describe(), 'transcode 720p adaptive (noCopyCandidate)');
      expect(
        const DirectPlayPlan(reason: PlanReason.directPlayAccepted).describe(),
        'directPlay (directPlayAccepted)',
      );
    });
  });
}
