import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/playback/playback_plan.dart';
import 'package:player/domain/models/quality_delivery_subtitle.dart';
import 'package:player/domain/models/quality_rung.dart';
import 'package:player/l10n/gen/app_localizations_en.dart';
import 'package:player/l10n/l10n.dart';

final _en = AppLocalizationsEn();

void main() {
  group('originalDelivery', () {
    test('prefers Direct Play when canDirectPlay is true', () {
      expect(
        originalDelivery(
          canDirectPlay: true,
          hasLosslessDelivery: true,
        ),
        OriginalDelivery.directPlay,
      );
      expect(
        originalDelivery(
          canDirectPlay: true,
          hasLosslessDelivery: false,
        ),
        OriginalDelivery.directPlay,
      );
    });

    test('uses lossless copy when direct play is unavailable', () {
      expect(
        originalDelivery(
          canDirectPlay: false,
          hasLosslessDelivery: true,
        ),
        OriginalDelivery.lossless,
      );
    });

    test('falls back to re-encoding required', () {
      expect(
        originalDelivery(
          canDirectPlay: false,
          hasLosslessDelivery: false,
        ),
        OriginalDelivery.transcode,
      );
    });
  });

  group('cappedRungDeliveryText', () {
    test('names the transcode and bitrate cap', () {
      expect(
        _en.cappedRungDeliveryText(4000),
        'Transcodes · up to 4000 kbps',
      );
    });

    test('falls back when bitrate is null', () {
      expect(_en.cappedRungDeliveryText(null), 'Transcodes');
    });
  });

  group('originalDeliveryForPlan', () {
    test('names the plan', () {
      expect(
        originalDeliveryForPlan(
          const DirectPlayPlan(reason: PlanReason.directPlayAccepted),
        ),
        OriginalDelivery.directPlay,
      );
      expect(
        originalDeliveryForPlan(const HlsPlan(
          strategy: HlsStrategy.copy,
          rung: QualityRung.original,
          adaptive: false,
          reason: PlanReason.copyAccepted,
        )),
        OriginalDelivery.lossless,
      );
      expect(
        originalDeliveryForPlan(const HlsPlan(
          strategy: HlsStrategy.transcode,
          rung: QualityRung.original,
          adaptive: false,
          reason: PlanReason.noCopyCandidate,
        )),
        OriginalDelivery.transcode,
      );
    });
  });

  group('originalDeliveryText', () {
    test('words every delivery', () {
      expect(
          _en.originalDeliveryText(OriginalDelivery.directPlay), 'Direct Play');
      expect(_en.originalDeliveryText(OriginalDelivery.lossless),
          'Original · no re-encoding');
      expect(_en.originalDeliveryText(OriginalDelivery.transcode),
          'Original · re-encoding required');
      expect(_en.originalDeliveryText(OriginalDelivery.preference),
          'Source quality');
    });
  });
}
