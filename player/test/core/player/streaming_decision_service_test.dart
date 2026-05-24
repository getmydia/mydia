import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/player/streaming_decision_service.dart';
import 'package:player/core/player/streaming_strategy.dart';
import 'package:player/domain/models/streaming_candidate.dart';

void main() {
  group('StreamingCandidate', () {
    test('fromJson parses candidate correctly', () {
      final json = {
        'strategy': 'DIRECT_PLAY',
        'mime': 'video/mp4; codecs="avc1.640028, mp4a.40.2"',
        'container': 'mp4',
        'video_codec': 'avc1.640028',
        'audio_codec': 'mp4a.40.2',
      };

      final candidate = StreamingCandidate.fromJson(json);

      expect(candidate.strategy, equals(StreamingStrategy.directPlay));
      expect(
          candidate.mime, equals('video/mp4; codecs="avc1.640028, mp4a.40.2"'));
      expect(candidate.container, equals('mp4'));
      expect(candidate.videoCodec, equals('avc1.640028'));
      expect(candidate.audioCodec, equals('mp4a.40.2'));
    });

    test('fromJson handles null audio codec', () {
      final json = {
        'strategy': 'REMUX',
        'mime': 'video/mp4; codecs="avc1.640028"',
        'container': 'mp4',
        'video_codec': 'avc1.640028',
        'audio_codec': null,
      };

      final candidate = StreamingCandidate.fromJson(json);

      expect(candidate.audioCodec, isNull);
    });

    test('fromJson throws on unknown strategy', () {
      final json = {
        'strategy': 'UNKNOWN_STRATEGY',
        'mime': 'video/mp4',
        'container': 'mp4',
        'video_codec': 'avc1.640028',
      };

      expect(
        () => StreamingCandidate.fromJson(json),
        throwsA(isA<FormatException>()),
      );
    });

    test('fromJson parses all strategy types', () {
      for (final strategy in StreamingStrategy.values) {
        final json = {
          'strategy': strategy.value,
          'mime': 'video/mp4',
          'container': 'mp4',
          'video_codec': 'avc1.640028',
        };

        final candidate = StreamingCandidate.fromJson(json);
        expect(candidate.strategy, equals(strategy));
      }
    });
  });

  group('StreamingMetadata', () {
    test('fromJson parses metadata correctly', () {
      final json = {
        'duration': 596.5,
        'width': 1920,
        'height': 1080,
        'bitrate': 5000000,
        'resolution': '1080p',
        'hdr_format': null,
        'original_codec': 'h264',
        'original_audio_codec': 'aac',
        'container': 'mp4',
      };

      final metadata = StreamingMetadata.fromJson(json);

      expect(metadata.duration, equals(596.5));
      expect(metadata.width, equals(1920));
      expect(metadata.height, equals(1080));
      expect(metadata.bitrate, equals(5000000));
      expect(metadata.resolution, equals('1080p'));
      expect(metadata.hdrFormat, isNull);
      expect(metadata.originalCodec, equals('h264'));
      expect(metadata.originalAudioCodec, equals('aac'));
      expect(metadata.container, equals('mp4'));
    });

    test('fromJson handles HDR format', () {
      final json = {
        'duration': 7200.0,
        'width': 3840,
        'height': 2160,
        'resolution': '4K',
        'hdr_format': 'HDR10',
        'original_codec': 'hevc',
      };

      final metadata = StreamingMetadata.fromJson(json);

      expect(metadata.resolution, equals('4K'));
      expect(metadata.hdrFormat, equals('HDR10'));
      expect(metadata.originalCodec, equals('hevc'));
    });

    test('fromJson handles all null values', () {
      final json = <String, dynamic>{};

      final metadata = StreamingMetadata.fromJson(json);

      expect(metadata.duration, isNull);
      expect(metadata.width, isNull);
      expect(metadata.height, isNull);
    });
  });

  group('StreamingCandidatesResponse', () {
    test('fromJson parses full response', () {
      final json = {
        'candidates': [
          {
            'strategy': 'DIRECT_PLAY',
            'mime': 'video/mp4; codecs="avc1.640028, mp4a.40.2"',
            'container': 'mp4',
            'video_codec': 'avc1.640028',
            'audio_codec': 'mp4a.40.2',
          },
          {
            'strategy': 'REMUX',
            'mime': 'video/mp4; codecs="avc1.640028, mp4a.40.2"',
            'container': 'mp4',
            'video_codec': 'avc1.640028',
            'audio_codec': 'mp4a.40.2',
          },
          {
            'strategy': 'HLS_COPY',
            'mime': 'video/mp2t; codecs="avc1.640028, mp4a.40.2"',
            'container': 'ts',
            'video_codec': 'avc1.640028',
            'audio_codec': 'mp4a.40.2',
          },
          {
            'strategy': 'TRANSCODE',
            'mime': 'video/mp2t; codecs="avc1.640028, mp4a.40.2"',
            'container': 'ts',
            'video_codec': 'avc1.640028',
            'audio_codec': 'mp4a.40.2',
          },
        ],
        'metadata': {
          'duration': 596.5,
          'width': 1920,
          'height': 1080,
          'bitrate': 5000000,
          'resolution': '1080p',
          'original_codec': 'h264',
          'original_audio_codec': 'aac',
          'container': 'mp4',
        },
      };

      final response = StreamingCandidatesResponse.fromJson(json);

      expect(response.candidates.length, equals(4));
      expect(response.candidates[0].strategy,
          equals(StreamingStrategy.directPlay));
      expect(response.candidates[1].strategy, equals(StreamingStrategy.remux));
      expect(
          response.candidates[2].strategy, equals(StreamingStrategy.hlsCopy));
      expect(
          response.candidates[3].strategy, equals(StreamingStrategy.transcode));
      expect(response.metadata.duration, equals(596.5));
      expect(response.metadata.resolution, equals('1080p'));
    });
  });

  group('StreamingDecision', () {
    test('success creates successful decision', () {
      final candidate = StreamingCandidate(
        strategy: StreamingStrategy.directPlay,
        mime: 'video/mp4',
        container: 'mp4',
        videoCodec: 'avc1.640028',
      );
      const metadata = StreamingMetadata(duration: 100.0);

      final decision = StreamingDecision.success(
        strategy: StreamingStrategy.directPlay,
        candidate: candidate,
        metadata: metadata,
      );

      expect(decision.success, isTrue);
      expect(decision.strategy, equals(StreamingStrategy.directPlay));
      expect(decision.candidate, equals(candidate));
      expect(decision.metadata, equals(metadata));
      expect(decision.error, isNull);
    });

    test('error creates failed decision', () {
      final decision = StreamingDecision.error('No supported format');

      expect(decision.success, isFalse);
      expect(decision.strategy, isNull);
      expect(decision.candidate, isNull);
      expect(decision.error, equals('No supported format'));
    });

    test('toString formats correctly for success', () {
      final candidate = StreamingCandidate(
        strategy: StreamingStrategy.hlsCopy,
        mime: 'video/mp2t',
        container: 'ts',
        videoCodec: 'avc1.640028',
      );
      const metadata = StreamingMetadata();

      final decision = StreamingDecision.success(
        strategy: StreamingStrategy.hlsCopy,
        candidate: candidate,
        metadata: metadata,
      );

      expect(decision.toString(), contains('success'));
      expect(decision.toString(), contains('HLS_COPY'));
    });

    test('toString formats correctly for error', () {
      final decision = StreamingDecision.error('Test error');

      expect(decision.toString(), contains('error'));
      expect(decision.toString(), contains('Test error'));
    });
  });

  group('StreamingDecisionService', () {
    test('isCandidateSupported returns true for TRANSCODE', () {
      const service = StreamingDecisionService(
        serverUrl: 'https://example.com',
        authToken: 'test-token',
      );

      final candidate = StreamingCandidate(
        strategy: StreamingStrategy.transcode,
        mime: 'video/mp2t; codecs="avc1.640028, mp4a.40.2"',
        container: 'ts',
        videoCodec: 'avc1.640028',
        audioCodec: 'mp4a.40.2',
      );

      // TRANSCODE is always supported
      expect(service.isCandidateSupported(candidate), isTrue);
    });

    test('isCandidateSupported returns true for all strategies on native', () {
      // In test environment (native), all strategies should be supported
      const service = StreamingDecisionService(
        serverUrl: 'https://example.com',
        authToken: 'test-token',
      );

      for (final strategy in StreamingStrategy.values) {
        final candidate = StreamingCandidate(
          strategy: strategy,
          mime: 'video/mp4; codecs="avc1.640028"',
          container: 'mp4',
          videoCodec: 'avc1.640028',
        );

        expect(service.isCandidateSupported(candidate), isTrue);
      }
    });

    test('selectBestCandidate returns first supported candidate', () {
      const service = StreamingDecisionService(
        serverUrl: 'https://example.com',
        authToken: 'test-token',
      );

      final candidates = [
        StreamingCandidate(
          strategy: StreamingStrategy.directPlay,
          mime: 'video/mp4; codecs="avc1.640028"',
          container: 'mp4',
          videoCodec: 'avc1.640028',
        ),
        StreamingCandidate(
          strategy: StreamingStrategy.transcode,
          mime: 'video/mp2t; codecs="avc1.640028"',
          container: 'ts',
          videoCodec: 'avc1.640028',
        ),
      ];

      final selected = service.selectBestCandidate(candidates);

      expect(selected, isNotNull);
      expect(selected!.strategy, equals(StreamingStrategy.directPlay));
    });

    test('selectBestCandidate returns null for empty list', () {
      const service = StreamingDecisionService(
        serverUrl: 'https://example.com',
        authToken: 'test-token',
      );

      final selected = service.selectBestCandidate([]);

      expect(selected, isNull);
    });

    test('buildStreamUrl constructs correct URL', () {
      const service = StreamingDecisionService(
        serverUrl: 'https://example.com',
        authToken: 'test-token',
      );

      final url = service.buildStreamUrl(
        fileId: 'file-123',
        strategy: StreamingStrategy.hlsCopy,
      );

      expect(
          url,
          equals(
              'https://example.com/api/v1/stream/file/file-123?strategy=HLS_COPY'));
    });

    test('buildStreamUrl includes media token when provided', () {
      const service = StreamingDecisionService(
        serverUrl: 'https://example.com',
        authToken: 'test-token',
        mediaToken: 'media-token-abc',
      );

      final url = service.buildStreamUrl(
        fileId: 'file-123',
        strategy: StreamingStrategy.directPlay,
      );

      expect(url, contains('token=media-token-abc'));
    });
  });
}
