// `pickHlsStrategy` is what `PlayerScreen._pickHlsStrategy` delegates to. A
// leading HLS_COPY candidate is the server's :needs_transcoding verdict
// (Mydia.Streaming.Candidates.build_streaming_candidates/2), and HLS_COPY
// never re-encodes, so it must never be requested in that case — that
// inversion is what let a Fire HD 10 (HEVC decoder is Main 8-bit only, no
// Main 10 support) stream an HEVC Main 10 file untouched and hit mpv's
// "Could not open codec.".

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/player/hls_strategy_selection.dart';

void main() {
  group('pickHlsStrategy', () {
    test(
        'a leading HLS_COPY (old-server :needs_transcoding shape) forces '
        'TRANSCODE', () {
      expect(
        pickHlsStrategy(['HLS_COPY', 'TRANSCODE']),
        'TRANSCODE',
      );
    });

    test(
        'multiple leading HLS_COPY variants (one per video codec variant) '
        'still force TRANSCODE', () {
      expect(
        pickHlsStrategy(['HLS_COPY', 'HLS_COPY', 'HLS_COPY', 'TRANSCODE']),
        'TRANSCODE',
      );
    });

    test('a later HLS_COPY behind REMUX (:needs_remux shape) is used', () {
      expect(
        pickHlsStrategy(['REMUX', 'HLS_COPY', 'TRANSCODE']),
        'HLS_COPY',
      );
    });

    test('a DIRECT_PLAY list with no HLS_COPY falls back to TRANSCODE', () {
      expect(
        pickHlsStrategy(['DIRECT_PLAY', 'TRANSCODE']),
        'TRANSCODE',
      );
    });

    test('a TRANSCODE-only list stays TRANSCODE', () {
      expect(
        pickHlsStrategy(['TRANSCODE']),
        'TRANSCODE',
      );
    });

    test('an empty list falls back to TRANSCODE', () {
      expect(
        pickHlsStrategy(const []),
        'TRANSCODE',
      );
    });

    test(
        'a server carrying the #564 fix that omits HLS_COPY outright still '
        'yields TRANSCODE', () {
      // PR #564 (server-side) omits HLS_COPY from the :needs_transcoding
      // branch entirely once the client's declared codecs reject the
      // source, so the list a fixed server sends here for that case has no
      // HLS_COPY entry at all.
      expect(
        pickHlsStrategy(['TRANSCODE']),
        'TRANSCODE',
      );
    });
  });
}
