import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/playback/candidates_from_graphql.dart';
import 'package:player/graphql/queries/streaming_candidates.graphql.dart';

void main() {
  test('maps generated candidates in order, keeping strategy, mime, codec', () {
    final generated = Query$StreamingCandidates$streamingCandidates.fromJson({
      '__typename': 'StreamingCandidatesResult',
      'fileId': 'file-1',
      'candidates': [
        {
          '__typename': 'StreamingCandidate',
          'strategy': 'REMUX',
          'mime': 'video/mp4; codecs="avc1.640028, mp4a.40.2"',
          'container': 'mp4',
          'videoCodec': 'avc1.640028',
          'audioCodec': 'mp4a.40.2',
        },
        {
          '__typename': 'StreamingCandidate',
          'strategy': 'TRANSCODE',
          'mime': 'video/mp2t',
          'container': 'ts',
          'videoCodec': null,
          'audioCodec': null,
        },
      ],
      'metadata': {
        '__typename': 'StreamingMetadata',
        'duration': null,
        'width': null,
        'height': null,
        'bitrate': 12345678,
        'preferredAudioLanguages': null,
      },
    });

    final mapped = candidateStrategiesFrom(generated.candidates);
    expect(mapped.map((c) => c.strategy), ['REMUX', 'TRANSCODE']);
    expect(mapped.first.mime, 'video/mp4; codecs="avc1.640028, mp4a.40.2"');
    expect(mapped.first.videoCodec, 'avc1.640028');
    expect(mapped.last.videoCodec, isNull);
    expect(kbpsFromBitsPerSecond(generated.metadata.bitrate), 12346);
  });

  test('null in, empty or null out', () {
    expect(candidateStrategiesFrom(null), isEmpty);
    expect(kbpsFromBitsPerSecond(null), isNull);
    expect(kbpsFromBitsPerSecond(0), isNull);
  });
}
