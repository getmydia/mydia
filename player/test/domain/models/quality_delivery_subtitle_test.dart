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

  group('hlsDeliveryIsLossless', () {
    test('false when HLS_COPY leads, because that copy is never requested', () {
      // The :needs_transcoding shape. pickHlsStrategy refuses a leading
      // HLS_COPY and asks for TRANSCODE instead, so the delivery re-encodes
      // however many HLS_COPY entries the server listed. Reporting these as
      // lossless is what put "Original · no re-encoding" on a web session
      // the dashboard showed re-encoding HEVC to H.264.
      expect(hlsDeliveryIsLossless(['HLS_COPY', 'TRANSCODE']), isFalse);
      expect(
        hlsDeliveryIsLossless(['HLS_COPY', 'HLS_COPY', 'TRANSCODE']),
        isFalse,
      );
    });

    test('true when HLS_COPY sits behind REMUX', () {
      // The :needs_remux shape, where the codecs are already compatible and
      // only the container is not. pickHlsStrategy requests that HLS_COPY.
      expect(
        hlsDeliveryIsLossless(['REMUX', 'HLS_COPY', 'TRANSCODE']),
        isTrue,
      );
    });

    test('false without any HLS_COPY to request', () {
      // Both of these fall through to TRANSCODE.
      expect(hlsDeliveryIsLossless(['DIRECT_PLAY', 'TRANSCODE']), isFalse);
      expect(hlsDeliveryIsLossless(['REMUX', 'TRANSCODE']), isFalse);
    });

    test('false when empty', () {
      expect(hlsDeliveryIsLossless([]), isFalse);
    });
  });

  group('originalDeliverySubtitle over real candidate lists', () {
    // Guards the pairing the bug broke: the same list must not be read as
    // direct-playable by one helper and lossless by the other.
    test('web HEVC session reports re-encoding, not lossless', () {
      const hevc = ['HLS_COPY', 'HLS_COPY', 'TRANSCODE'];
      expect(
        originalDeliverySubtitle(
          canDirectPlay: false, // kIsWeb forces this false
          hasLosslessDelivery: hlsDeliveryIsLossless(hevc),
        ),
        kOriginalTranscodeSubtitle,
      );
    });

    test('web remux session still reports lossless', () {
      const remux = ['REMUX', 'HLS_COPY', 'TRANSCODE'];
      expect(
        originalDeliverySubtitle(
          canDirectPlay: false,
          hasLosslessDelivery: hlsDeliveryIsLossless(remux),
        ),
        kOriginalLosslessSubtitle,
      );
    });
  });
}
