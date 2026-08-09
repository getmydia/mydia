import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/models/quality_delivery_subtitle.dart';

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
        'Direct Play',
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
  });

  group('strategiesAllowNativeDirectPlay', () {
    test('true when first is DIRECT_PLAY, REMUX, or HLS_COPY', () {
      expect(
        strategiesAllowNativeDirectPlay(['DIRECT_PLAY', 'TRANSCODE']),
        isTrue,
      );
      expect(
        strategiesAllowNativeDirectPlay(['REMUX', 'HLS_COPY', 'TRANSCODE']),
        isTrue,
      );
      expect(
        strategiesAllowNativeDirectPlay(['HLS_COPY', 'TRANSCODE']),
        isTrue,
      );
    });

    test('false when empty or first is TRANSCODE', () {
      expect(strategiesAllowNativeDirectPlay([]), isFalse);
      expect(strategiesAllowNativeDirectPlay(['TRANSCODE']), isFalse);
    });
  });

  group('strategiesAllowLosslessDelivery', () {
    test('true when any HLS_COPY or REMUX is present', () {
      expect(
        strategiesAllowLosslessDelivery(['REMUX', 'TRANSCODE']),
        isTrue,
      );
      expect(
        strategiesAllowLosslessDelivery(['HLS_COPY', 'TRANSCODE']),
        isTrue,
      );
    });

    test('false for DIRECT_PLAY + TRANSCODE only (web direct-play shape)', () {
      expect(
        strategiesAllowLosslessDelivery(['DIRECT_PLAY', 'TRANSCODE']),
        isFalse,
      );
    });
  });
}
