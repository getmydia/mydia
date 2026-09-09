/// The one place generated GraphQL candidate types meet the planner's own.
library;

import '../../graphql/queries/streaming_candidates.graphql.dart';
import 'playback_plan.dart';

List<CandidateStrategy> candidateStrategiesFrom(
  List<Query$StreamingCandidates$streamingCandidates$candidates>? candidates,
) =>
    [
      for (final c in candidates ?? const [])
        CandidateStrategy(
          strategy: c.strategy.toJson(),
          mime: c.mime,
          videoCodec: c.videoCodec,
        ),
    ];

/// `streamingMetadata.bitrate` is bits per second; the planner and the
/// rungs speak kbps. Zero or missing is unknown, never "free".
int? kbpsFromBitsPerSecond(int? bps) {
  if (bps == null || bps <= 0) return null;
  return (bps / 1000).round();
}
