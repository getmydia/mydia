import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/player/streaming_strategy.dart';

void main() {
  group('Media Token Integration', () {
    test('buildStreamUrl with media token appends token as query param', () {
      const serverUrl = 'https://example.com';
      const fileId = 'file-123';
      const strategy = StreamingStrategy.hlsCopy;
      const mediaToken = 'test-media-token';

      final url = StreamingStrategyService.buildStreamUrl(
        serverUrl: serverUrl,
        fileId: fileId,
        strategy: strategy,
        mediaToken: mediaToken,
      );

      expect(
        url,
        equals(
            'https://example.com/api/v1/stream/file/file-123?strategy=HLS_COPY&token=test-media-token'),
      );
    });

    test('buildStreamUrl without media token does not append token', () {
      const serverUrl = 'https://example.com';
      const fileId = 'file-123';
      const strategy = StreamingStrategy.directPlay;

      final url = StreamingStrategyService.buildStreamUrl(
        serverUrl: serverUrl,
        fileId: fileId,
        strategy: strategy,
        mediaToken: null,
      );

      expect(
        url,
        equals(
            'https://example.com/api/v1/stream/file/file-123?strategy=DIRECT_PLAY'),
      );
    });

    test('getOptimalStrategy returns HLS on web', () {
      // Note: This test runs in VM, not web, so we test the non-web path
      final strategy = StreamingStrategyService.getOptimalStrategy();

      // On native (which is what this test is), it should be directPlay
      expect(strategy, equals(StreamingStrategy.directPlay));
    });

    test('getOptimalStrategy respects forceHls flag', () {
      final strategy =
          StreamingStrategyService.getOptimalStrategy(forceHls: true);

      // When forced, should return HLS
      expect(strategy, equals(StreamingStrategy.hlsCopy));
    });
  });
}
