/// Turns the server's candidates and this install's memory into a plan.
///
/// Pure. Every rule and its order is spelled out in the spec under "The
/// decision"; the reason on the returned plan names the rule that decided.
library;

import '../../domain/models/quality_rung.dart';
import 'playback_memory.dart';
import 'playback_plan.dart';

/// A file's bitrate must fit under throughput with this much room.
const double kThroughputHeadroom = 1.3;

class PlanInputs {
  const PlanInputs({
    required this.candidates,
    required this.isWeb,
    required this.typeSupported,
    required this.choice,
    this.sourceHeight,
    this.fileBitrateKbps,
    this.knownThroughputKbps,
    this.knownFailures = const {},
  });

  /// `streamingCandidates.candidates` in server order.
  final List<CandidateStrategy> candidates;
  final bool isWeb;

  /// `MediaSource.isTypeSupported` on web. Native never calls it.
  final bool Function(String mime) typeSupported;
  final QualityChoice choice;
  final int? sourceHeight;

  /// `streamingCandidates.metadata.bitrate` divided by 1000.
  final int? fileBitrateKbps;

  /// This server's remembered throughput, if any.
  final int? knownThroughputKbps;

  /// Shapes that failed to decode against this server.
  final Set<FailureKey> knownFailures;

  PlanInputs copyWith({QualityChoice? choice}) => PlanInputs(
        candidates: candidates,
        isWeb: isWeb,
        typeSupported: typeSupported,
        choice: choice ?? this.choice,
        sourceHeight: sourceHeight,
        fileBitrateKbps: fileBitrateKbps,
        knownThroughputKbps: knownThroughputKbps,
        knownFailures: knownFailures,
      );

  FileShape get shape =>
      FileShape.fromCandidates(candidates, sourceHeight: sourceHeight);
}

/// Whether a file of [fileBitrateKbps] plays over [throughputKbps] with
/// [kThroughputHeadroom]. Either unknown passes.
bool bitrateFits({
  required int? fileBitrateKbps,
  required int? throughputKbps,
}) {
  if (fileBitrateKbps == null || throughputKbps == null) return true;
  return fileBitrateKbps * kThroughputHeadroom <= throughputKbps;
}

/// The rung an adaptive transcode starts at: the highest whose bitrate fits
/// [throughputKbps] with headroom; the top when throughput is unknown; the
/// bottom when nothing fits; Original when the ladder is empty.
QualityRung startingRung(List<QualityRung> ladder, int? throughputKbps) {
  if (ladder.isEmpty) return QualityRung.original;
  if (throughputKbps == null) return ladder.first;
  for (final rung in ladder) {
    if (bitrateFits(
      fileBitrateKbps: rung.maxBitrateKbps,
      throughputKbps: throughputKbps,
    )) {
      return rung;
    }
  }
  return ladder.last;
}

/// The transcode plan a failed direct play or copy source falls back to.
///
/// Always adaptive, whatever the viewer had chosen: a choice that could not
/// be honoured becomes Auto for the rest of the session. With throughput
/// unknown the rung is one below the top, or the top of a one-rung ladder.
HlsPlan fallbackPlan({
  required int? sourceHeight,
  required int? throughputKbps,
}) {
  final ladder = deriveAdaptiveLadder(sourceHeight: sourceHeight);
  final QualityRung rung;
  if (ladder.isEmpty) {
    rung = QualityRung.original;
  } else if (throughputKbps != null) {
    rung = startingRung(ladder, throughputKbps);
  } else {
    rung = ladder.length > 1 ? ladder[1] : ladder.first;
  }
  return HlsPlan(
    strategy: HlsStrategy.transcode,
    rung: rung,
    adaptive: true,
    reason: PlanReason.fallbackFromFailure,
  );
}

bool _leadsWithDirect(List<CandidateStrategy> candidates) {
  if (candidates.isEmpty) return false;
  final first = candidates.first.strategy;
  return first == 'DIRECT_PLAY' || first == 'REMUX';
}

/// A copy candidate that is not the leading entry. A leading HLS_COPY is the
/// server's :needs_transcoding verdict and carries the codec it just said
/// this device cannot decode. Older servers can emit more HLS_COPY variants
/// after that verdict, so none of that list is a candidate here.
CandidateStrategy? _nonLeadingCopy(List<CandidateStrategy> candidates) {
  if (candidates.isNotEmpty && candidates.first.strategy == 'HLS_COPY') {
    return null;
  }

  for (var i = 1; i < candidates.length; i++) {
    if (candidates[i].strategy == 'HLS_COPY') return candidates[i];
  }
  return null;
}

PlaybackPlan planPlayback(PlanInputs inputs) {
  final choice = inputs.choice;

  if (choice.kind == QualityChoiceKind.fixed) {
    return HlsPlan(
      strategy: HlsStrategy.transcode,
      rung: choice.rung!,
      adaptive: false,
      reason: PlanReason.fixedRungRequested,
    );
  }

  final failureKey = FailureKey.fromShape(inputs.shape);
  final knownToFail = choice.kind == QualityChoiceKind.auto &&
      inputs.knownFailures.contains(failureKey);
  final fits = bitrateFits(
    fileBitrateKbps: inputs.fileBitrateKbps,
    throughputKbps: inputs.knownThroughputKbps,
  );

  // Rule 1: direct play.
  final PlanReason blocker;
  if (inputs.isWeb) {
    blocker = PlanReason.webNeverDirectPlays;
  } else if (!_leadsWithDirect(inputs.candidates)) {
    blocker = PlanReason.noDirectPlayCandidate;
  } else if (knownToFail) {
    blocker = PlanReason.shapeKnownToFail;
  } else if (!fits) {
    blocker = PlanReason.bitrateExceedsThroughput;
  } else {
    return const DirectPlayPlan(reason: PlanReason.directPlayAccepted);
  }

  // Rule 2: copy. The same decoder sees the same codec, and the same link
  // carries the same bytes, so a decode or bandwidth blocker holds here.
  var reason = blocker;
  final copy = _nonLeadingCopy(inputs.candidates);
  if (knownToFail) {
    reason = PlanReason.shapeKnownToFail;
  } else if (!fits) {
    reason = PlanReason.bitrateExceedsThroughput;
  } else if (copy == null) {
    reason = PlanReason.noCopyCandidate;
  } else if (inputs.isWeb && !inputs.typeSupported(copy.mime)) {
    reason = PlanReason.copyRejectedByMime;
  } else {
    return const HlsPlan(
      strategy: HlsStrategy.copy,
      rung: QualityRung.original,
      adaptive: false,
      reason: PlanReason.copyAccepted,
    );
  }

  // Rule 3: transcode.
  final adaptive = choice.kind == QualityChoiceKind.auto;
  final rung = adaptive
      ? startingRung(
          deriveAdaptiveLadder(sourceHeight: inputs.sourceHeight),
          inputs.knownThroughputKbps,
        )
      : QualityRung.original;

  // When there was no copy candidate at all, and direct play was blocked by
  // the platform or the list rather than by memory or bandwidth, the
  // structural blocker is the more useful thing to log.
  final structural = blocker == PlanReason.noDirectPlayCandidate ||
      blocker == PlanReason.webNeverDirectPlays;
  final reported = copy == null && structural ? blocker : reason;

  return HlsPlan(
    strategy: HlsStrategy.transcode,
    rung: rung,
    adaptive: adaptive,
    reason: reported,
  );
}
