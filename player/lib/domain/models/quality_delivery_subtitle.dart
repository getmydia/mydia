/// How a quality rung will be delivered, as typed values. The viewer-facing
/// subtitles are worded by `AppFormatters.originalDeliveryText` and
/// `AppFormatters.cappedRungDeliveryText`.
library;

import '../../core/playback/playback_plan.dart';

/// What the Original rung does, shown under it in the quality picker.
enum OriginalDelivery {
  /// The file plays as it is on this device.
  directPlay,

  /// The server repackages the video without re-encoding it.
  lossless,

  /// The server must re-encode the video.
  transcode,

  /// No delivery context (e.g. Settings): just says it is the source quality.
  preference,
}

/// The Original delivery for what the player could do.
///
/// [canDirectPlay] means native and the same candidate gate the planner
/// applies for a [DirectPlayPlan] (ignore the currently selected rung).
/// [hasLosslessDelivery] means the HLS session will copy the video rather
/// than re-encode it, per [originalDeliveryForPlan].
/// Ordering: direct play, then lossless, then re-encoding required.
OriginalDelivery originalDelivery({
  required bool canDirectPlay,
  required bool hasLosslessDelivery,
}) {
  if (canDirectPlay) return OriginalDelivery.directPlay;
  if (hasLosslessDelivery) return OriginalDelivery.lossless;
  return OriginalDelivery.transcode;
}

/// The Original delivery for what the planner would do with the Original
/// choice: direct play, stream copy, or a transcode.
///
/// This is the single source of truth for the label: the planner already
/// refuses a leading `HLS_COPY` (the server's `:needs_transcoding` verdict
/// still carries the codec this device cannot decode — see
/// `_nonLeadingCopy` in `playback_planner.dart`) and falls back to a
/// transcode, so the plan this reads from can never claim a re-encode is
/// lossless. A 1080p HEVC episode therefore reports "Original · re-encoding
/// required" here, matching what the server dashboard shows.
OriginalDelivery originalDeliveryForPlan(PlaybackPlan plan) => switch (plan) {
      DirectPlayPlan() => OriginalDelivery.directPlay,
      HlsPlan(strategy: HlsStrategy.copy) => OriginalDelivery.lossless,
      HlsPlan() => OriginalDelivery.transcode,
    };
