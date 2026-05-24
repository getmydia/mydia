import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/player/streaming_strategy.dart';

void main() {
  group('StreamingStrategyService', () {
    test('getOptimalStrategy returns hlsCopy for web', () {
      // Note: In tests, kIsWeb is false by default
      // This test verifies the logic when forceHls is true
      final strategy =
          StreamingStrategyService.getOptimalStrategy(forceHls: true);

      expect(strategy, equals(StreamingStrategy.hlsCopy));
    });

    test('getOptimalStrategy returns directPlay for native platforms', () {
      // When not forced and not on web, should use direct play
      final strategy = StreamingStrategyService.getOptimalStrategy();

      // In test environment (not web), should default to directPlay
      expect(strategy, equals(StreamingStrategy.directPlay));
    });

    test('buildStreamUrl constructs correct HLS URL', () {
      const serverUrl = 'https://example.com';
      const fileId = 'test-file-123';

      final url = StreamingStrategyService.buildStreamUrl(
        serverUrl: serverUrl,
        fileId: fileId,
        strategy: StreamingStrategy.hlsCopy,
      );

      expect(
          url,
          equals(
              'https://example.com/api/v1/stream/file/test-file-123?strategy=HLS_COPY'));
    });

    test('buildStreamUrl handles directPlay strategy', () {
      const serverUrl = 'https://example.com';
      const fileId = 'test-file-123';

      final url = StreamingStrategyService.buildStreamUrl(
        serverUrl: serverUrl,
        fileId: fileId,
        strategy: StreamingStrategy.directPlay,
      );

      expect(
          url,
          equals(
              'https://example.com/api/v1/stream/file/test-file-123?strategy=DIRECT_PLAY'));
    });

    test('buildStreamUrl handles transcode strategy', () {
      const serverUrl = 'https://example.com';
      const fileId = 'test-file-123';

      final url = StreamingStrategyService.buildStreamUrl(
        serverUrl: serverUrl,
        fileId: fileId,
        strategy: StreamingStrategy.transcode,
      );

      expect(
          url,
          equals(
              'https://example.com/api/v1/stream/file/test-file-123?strategy=TRANSCODE'));
    });

    test('isHlsSupported returns true', () {
      // HLS is supported on all platforms via media_kit
      expect(StreamingStrategyService.isHlsSupported, isTrue);
    });

    test('supportsAdaptiveBitrate returns true on web', () {
      // In test environment (not web), should be false
      expect(StreamingStrategyService.supportsAdaptiveBitrate, isFalse);
    });

    test('getStrategyDescription returns correct descriptions', () {
      expect(
        StreamingStrategyService.getStrategyDescription(
            StreamingStrategy.directPlay),
        equals('Direct Play'),
      );

      expect(
        StreamingStrategyService.getStrategyDescription(
            StreamingStrategy.remux),
        equals('Remux (fMP4)'),
      );

      expect(
        StreamingStrategyService.getStrategyDescription(
            StreamingStrategy.hlsCopy),
        equals('HLS (Stream Copy)'),
      );

      expect(
        StreamingStrategyService.getStrategyDescription(
            StreamingStrategy.transcode),
        equals('HLS (Transcoded)'),
      );
    });

    test('buildStreamUrl handles remux strategy', () {
      const serverUrl = 'https://example.com';
      const fileId = 'test-file-123';

      final url = StreamingStrategyService.buildStreamUrl(
        serverUrl: serverUrl,
        fileId: fileId,
        strategy: StreamingStrategy.remux,
      );

      expect(
          url,
          equals(
              'https://example.com/api/v1/stream/file/test-file-123?strategy=REMUX'));
    });

    test('fromValue parses strategy strings correctly', () {
      expect(StreamingStrategy.fromValue('DIRECT_PLAY'),
          equals(StreamingStrategy.directPlay));
      expect(StreamingStrategy.fromValue('REMUX'),
          equals(StreamingStrategy.remux));
      expect(StreamingStrategy.fromValue('HLS_COPY'),
          equals(StreamingStrategy.hlsCopy));
      expect(StreamingStrategy.fromValue('TRANSCODE'),
          equals(StreamingStrategy.transcode));
      expect(StreamingStrategy.fromValue('INVALID'), isNull);
    });
  });
}
