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

  group('nativeDirectPlayAllowed', () {
    test('unknown candidates mean direct play, not a transcode', () {
      // A null list is a transport failure, not a verdict. Falling back to a
      // transcode asks a server we just failed to reach to do more work, and
      // on 2026-09-08 that produced no playback at all for a file mpv decodes.
      expect(
        nativeDirectPlayAllowed(strategyValues: null, isOriginalQuality: true),
        isTrue,
      );
    });

    test('a chosen rung still vetoes, known candidates or not', () {
      // Direct play hands the file over untouched, so there is no encoder to
      // give the rung's height and bitrate caps to.
      expect(
        nativeDirectPlayAllowed(strategyValues: null, isOriginalQuality: false),
        isFalse,
      );
      expect(
        nativeDirectPlayAllowed(
          strategyValues: const ['DIRECT_PLAY', 'TRANSCODE'],
          isOriginalQuality: false,
        ),
        isFalse,
      );
    });

    test('known candidates are still judged on their leading strategy', () {
      expect(
        nativeDirectPlayAllowed(
          strategyValues: const ['DIRECT_PLAY', 'TRANSCODE'],
          isOriginalQuality: true,
        ),
        isTrue,
      );
      expect(
        nativeDirectPlayAllowed(
          strategyValues: const ['REMUX', 'HLS_COPY', 'TRANSCODE'],
          isOriginalQuality: true,
        ),
        isTrue,
      );
      // A leading HLS_COPY is the server's :needs_transcoding verdict. Unknown
      // meaning direct play must not become a way to smuggle past it.
      expect(
        nativeDirectPlayAllowed(
          strategyValues: const ['HLS_COPY', 'TRANSCODE'],
          isOriginalQuality: true,
        ),
        isFalse,
      );
      expect(
        nativeDirectPlayAllowed(
          strategyValues: const [],
          isOriginalQuality: true,
        ),
        isFalse,
      );
    });
  });
}
