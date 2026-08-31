import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/player/hls_strategy_selection.dart';
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

  group('firstStrategyAllowsDirectPlay', () {
    test('true when first is DIRECT_PLAY or REMUX', () {
      expect(
        firstStrategyAllowsDirectPlay(['DIRECT_PLAY', 'TRANSCODE']),
        isTrue,
      );
      expect(
        firstStrategyAllowsDirectPlay(['REMUX', 'HLS_COPY', 'TRANSCODE']),
        isTrue,
      );
    });

    test('false when first is HLS_COPY, even with nothing else ahead of it',
        () {
      // A leading HLS_COPY is the server's :needs_transcoding verdict
      // (Mydia.Streaming.Candidates.build_streaming_candidates/2) and
      // HLS_COPY never re-encodes, so it still carries a codec the device
      // was just told it cannot decode.
      expect(
        firstStrategyAllowsDirectPlay(['HLS_COPY', 'TRANSCODE']),
        isFalse,
      );
    });

    test('false when empty or first is TRANSCODE', () {
      expect(firstStrategyAllowsDirectPlay([]), isFalse);
      expect(firstStrategyAllowsDirectPlay(['TRANSCODE']), isFalse);
    });
  });

  group('strategiesAllowLosslessDelivery', () {
    test('true when an HLS_COPY sits behind a leading REMUX', () {
      // The :needs_remux shape. The codecs are already known compatible and
      // only the container is not, so this HLS_COPY is genuine.
      expect(
        strategiesAllowLosslessDelivery(['REMUX', 'HLS_COPY', 'TRANSCODE']),
        isTrue,
      );
    });

    test('false for a leading REMUX with no HLS_COPY behind it', () {
      // Native reports this through the canDirectPlay arm instead, and web
      // never requests REMUX — it forces an HLS session, which for this list
      // is a TRANSCODE.
      expect(
        strategiesAllowLosslessDelivery(['REMUX', 'TRANSCODE']),
        isFalse,
      );
    });

    test('false when HLS_COPY leads (the :needs_transcoding shape)', () {
      // A leading HLS_COPY is the server's :needs_transcoding verdict, and
      // pickHlsStrategy refuses it for exactly that reason — it requests
      // TRANSCODE instead. Calling that delivery "lossless" labelled a real
      // re-encode as "Original · no re-encoding", which is what an HEVC file
      // in a browser looks like: the server re-encodes to H.264, the browser
      // plays it, and the label credits the browser with HEVC decoding it
      // never did.
      expect(
        strategiesAllowLosslessDelivery(['HLS_COPY', 'TRANSCODE']),
        isFalse,
      );
    });

    test('false for DIRECT_PLAY + TRANSCODE only (web direct-play shape)', () {
      expect(
        strategiesAllowLosslessDelivery(['DIRECT_PLAY', 'TRANSCODE']),
        isFalse,
      );
    });
  });

  group('label agrees with the strategy actually requested', () {
    // The defect this guards: two functions read the same candidate list and
    // disagreed. pickHlsStrategy returned TRANSCODE for a leading HLS_COPY
    // while strategiesAllowLosslessDelivery called the same list lossless.
    for (final strategies in const [
      ['HLS_COPY', 'TRANSCODE'],
      ['HLS_COPY', 'HLS_COPY', 'TRANSCODE'],
      ['REMUX', 'HLS_COPY', 'TRANSCODE'],
      ['DIRECT_PLAY', 'TRANSCODE'],
      ['TRANSCODE'],
    ]) {
      test('$strategies', () {
        final reEncodes = pickHlsStrategy(strategies) == 'TRANSCODE';
        final subtitle = originalDeliverySubtitle(
          // Web never direct-plays; this is the browser case.
          canDirectPlay: false,
          hasLosslessDelivery: strategiesAllowLosslessDelivery(strategies),
        );

        expect(
          subtitle == kOriginalTranscodeSubtitle,
          reEncodes,
          reason: 'label "$subtitle" must match '
              'pickHlsStrategy = ${pickHlsStrategy(strategies)}',
        );
      });
    }
  });
}
