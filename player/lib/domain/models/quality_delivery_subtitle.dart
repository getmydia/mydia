/// User-facing subtitles for how a quality rung will be delivered.
library;

import '../../core/playback/playback_plan.dart';
import 'quality_rung.dart';

const kOriginalDirectPlaySubtitle = 'Direct Play';
const kOriginalLosslessSubtitle = 'Original · no re-encoding';
const kOriginalTranscodeSubtitle = 'Original · re-encoding required';

/// Neutral Original subtitle when there is no delivery context (e.g. Settings).
const kOriginalPreferenceSubtitle = 'Source quality';

/// Subtitle for the Original rung given what the player could do.
///
/// [canDirectPlay] means native and the same candidate gate the planner
/// applies for a [DirectPlayPlan] (ignore the currently selected rung).
/// [hasLosslessDelivery] means the HLS session will copy the video rather
/// than re-encode it, per [deliverySubtitleForPlan].
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
///
/// This is the single source of truth for the label: the planner already
/// refuses a leading `HLS_COPY` (the server's `:needs_transcoding` verdict
/// still carries the codec this device cannot decode — see
/// `_nonLeadingCopy` in `playback_planner.dart`) and falls back to a
/// transcode, so the plan this reads from can never claim a re-encode is
/// lossless. A 1080p HEVC episode therefore reports "Original · re-encoding
/// required" here, matching what the server dashboard shows.
String deliverySubtitleForPlan(PlaybackPlan plan) => switch (plan) {
      DirectPlayPlan() => kOriginalDirectPlaySubtitle,
      HlsPlan(strategy: HlsStrategy.copy) => kOriginalLosslessSubtitle,
      HlsPlan() => kOriginalTranscodeSubtitle,
    };

/// Neutral Auto subtitle when there is no delivery context (e.g. Settings).
const kAutoPreferenceSubtitle = 'Adapts to your connection';

/// The Auto row's subtitle for [plan]: what Auto is doing, or would do.
///
/// [effective] is the rung the server echoed for a transcode, which on a
/// relay can sit below the one Auto asked for; the row names what is
/// actually playing.
String autoDeliverySubtitle(PlaybackPlan plan, {QualityRung? effective}) =>
    switch (plan) {
      DirectPlayPlan() => 'Auto · Direct Play',
      HlsPlan(strategy: HlsStrategy.copy) => 'Auto · Original, no re-encoding',
      HlsPlan(:final rung) => _autoTranscodeSubtitle(effective ?? rung),
    };

String _autoTranscodeSubtitle(QualityRung rung) => rung.isOriginal
    ? 'Auto · Original, re-encoding required'
    : 'Auto · ${rung.label}';
