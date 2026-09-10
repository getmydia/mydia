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

  group('autoDeliverySubtitle', () {
    const r720 = QualityRung(label: '720p', height: 720, maxBitrateKbps: 4000);
    const r1080 =
        QualityRung(label: '1080p', height: 1080, maxBitrateKbps: 8000);

    test('names direct play, copy and the transcode rung', () {
      expect(
        autoDeliverySubtitle(
            const DirectPlayPlan(reason: PlanReason.directPlayAccepted)),
        'Auto · Direct Play',
      );
      expect(
        autoDeliverySubtitle(const HlsPlan(
          strategy: HlsStrategy.copy,
          rung: QualityRung.original,
          adaptive: false,
          reason: PlanReason.copyAccepted,
        )),
        'Auto · Original, no re-encoding',
      );
      expect(
        autoDeliverySubtitle(const HlsPlan(
          strategy: HlsStrategy.transcode,
          rung: r720,
          adaptive: true,
          reason: PlanReason.noDirectPlayCandidate,
        )),
        'Auto · 720p',
      );
    });

    test('a transcode with no adaptive ladder re-encodes at Original', () {
      expect(
        autoDeliverySubtitle(const HlsPlan(
          strategy: HlsStrategy.transcode,
          rung: QualityRung.original,
          adaptive: true,
          reason: PlanReason.noDirectPlayCandidate,
        )),
        'Auto · Original, re-encoding required',
      );
    });

    test('names what the server applied over what Auto asked for', () {
      expect(
        autoDeliverySubtitle(
          const HlsPlan(
            strategy: HlsStrategy.transcode,
            rung: r1080,
            adaptive: true,
            reason: PlanReason.noDirectPlayCandidate,
          ),
          effective: r720,
        ),
        'Auto · 720p',
      );
    });

    test('the preference subtitle is neutral', () {
      expect(kAutoPreferenceSubtitle, 'Adapts to your connection');
    });
  });
}
