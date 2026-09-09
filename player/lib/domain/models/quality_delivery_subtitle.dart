/// User-facing subtitles for how a quality rung will be delivered.
///
/// See `docs/superpowers/specs/2026-08-09-player-quality-delivery-labels-design.md`.

import '../../core/playback/playback_plan.dart';

const kOriginalDirectPlaySubtitle = 'Direct Play';
const kOriginalLosslessSubtitle = 'Original · no re-encoding';
const kOriginalTranscodeSubtitle = 'Original · re-encoding required';

/// Neutral Original subtitle when there is no delivery context (e.g. Settings).
const kOriginalPreferenceSubtitle = 'Source quality';

/// Subtitle for the Original rung given what the player could do.
///
/// [canDirectPlay] means native and the same candidate gate as
/// `PlayerScreen._canDirectPlay` (ignore the currently selected rung).
/// [hasLosslessDelivery] means any candidate is HLS_COPY or REMUX.
/// Ordering: Direct Play, then lossless, then re-encoding required.
String originalDeliverySubtitle({
  required bool canDirectPlay,
  required bool hasLosslessDelivery,
}) {
  if (canDirectPlay) return kOriginalDirectPlaySubtitle;
  if (hasLosslessDelivery) return kOriginalLosslessSubtitle;
  return kOriginalTranscodeSubtitle;
}

/// Subtitle for a capped ladder rung (always re-encodes today).
///
/// When [maxBitrateKbps] is null, returns a bitrate-free label rather than
/// crashing — off-ladder synthesised rungs can omit a cap.
String cappedRungDeliverySubtitle(int? maxBitrateKbps) {
  if (maxBitrateKbps == null) return 'Transcodes';
  return 'Transcodes · up to $maxBitrateKbps kbps';
}

/// The Original subtitle for what the planner would do with the Original
/// choice: direct play, stream copy, or a transcode.
String deliverySubtitleForPlan(PlaybackPlan plan) => switch (plan) {
      DirectPlayPlan() => kOriginalDirectPlaySubtitle,
      HlsPlan(strategy: HlsStrategy.copy) => kOriginalLosslessSubtitle,
      HlsPlan() => kOriginalTranscodeSubtitle,
    };
