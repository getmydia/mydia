import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/playback/playback_plan.dart';
import 'package:player/domain/models/quality_delivery_subtitle.dart';
import 'package:player/domain/models/quality_rung.dart';

void main() {
  group('originalDeliverySubtitle', () {
    test('prefers Direct Play when canDirectPlay is true', () {
      expect(
        originalDeliverySubtitle(
          canDirectPlay: true,
          hasLosslessDelivery: true,
        ),
        kOriginalDirectPlaySubtitle,
      );
      expect(
        originalDeliverySubtitle(
          canDirectPlay: true,
          hasLosslessDelivery: false,
        ),
        kOriginalDirectPlaySubtitle,
      );
    });

    test('uses lossless copy when direct play is unavailable', () {
      expect(
        originalDeliverySubtitle(
          canDirectPlay: false,
          hasLosslessDelivery: true,
        ),
        kOriginalLosslessSubtitle,
      );
    });

    test('falls back to re-encoding required', () {
      expect(
        originalDeliverySubtitle(
          canDirectPlay: false,
          hasLosslessDelivery: false,
        ),
        kOriginalTranscodeSubtitle,
      );
    });
  });

  group('cappedRungDeliverySubtitle', () {
    test('names the transcode and bitrate cap', () {
      expect(
        cappedRungDeliverySubtitle(4000),
        'Transcodes · up to 4000 kbps',
      );
    });

    test('falls back when bitrate is null', () {
      expect(cappedRungDeliverySubtitle(null), 'Transcodes');
    });
  });

  group('deliverySubtitleForPlan', () {
    test('names the plan', () {
      expect(
        deliverySubtitleForPlan(
          const DirectPlayPlan(reason: PlanReason.directPlayAccepted),
        ),
        kOriginalDirectPlaySubtitle,
      );
      expect(
        deliverySubtitleForPlan(const HlsPlan(
          strategy: HlsStrategy.copy,
          rung: QualityRung.original,
          adaptive: false,
          reason: PlanReason.copyAccepted,
        )),
        kOriginalLosslessSubtitle,
      );
      expect(
        deliverySubtitleForPlan(const HlsPlan(
          strategy: HlsStrategy.transcode,
          rung: QualityRung.original,
          adaptive: false,
          reason: PlanReason.noCopyCandidate,
        )),
        kOriginalTranscodeSubtitle,
      );
    });
  });
}
