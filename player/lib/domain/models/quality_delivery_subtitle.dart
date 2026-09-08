/// User-facing subtitles for how a quality rung will be delivered.
///
/// See `docs/superpowers/specs/2026-08-09-player-quality-delivery-labels-design.md`.

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

/// Whether the first candidate strategy is one `PlayerScreen._canDirectPlay`
/// would accept (DIRECT_PLAY or REMUX).
///
/// `HLS_COPY` is deliberately excluded, even when it leads the list.
/// `Mydia.Streaming.Candidates.build_streaming_candidates/2` only ever leads
/// with `HLS_COPY` from its `:needs_transcoding` branch, and `HLS_COPY`
/// repackages a stream without re-encoding it — so a leading `HLS_COPY`
/// always still carries the exact video codec the server just said this
/// device cannot decode. Treating it as direct-playable let a Fire HD 10
/// (whose HEVC decoder is Main 8-bit only, with no Main 10 support) stream
/// an HEVC Main 10 file untouched, straight into mpv's "Could not open
/// codec." `REMUX` stays accepted: it only repackages a codec the
/// compatibility check already found acceptable into a different
/// container.
///
/// This guard used to stay permissive on the theory that the native device
/// profile the server checks against hadn't been validated on real hardware
/// and might under-report a device's true decoder support. That hedge no
/// longer applies: `android_codec_capabilities.dart`'s `MediaCodecList` probe
/// against a Fire HD 10 confirmed its decoder is exactly as limited as the
/// server's verdict assumed — `video/hevc` capped at 8-bit, `video/vp9` capped
/// at 10-bit — so a `:needs_transcoding` verdict for a codec this device
/// cannot decode is trustworthy, and HLS_COPY must not be used to second-guess
/// it.
///
/// Platform gating (`!kIsWeb`) is intentionally left to the caller — this
/// only inspects strategy ordering.
bool firstStrategyAllowsDirectPlay(Iterable<String> strategyValues) {
  final iterator = strategyValues.iterator;
  if (!iterator.moveNext()) return false;
  final first = iterator.current;
  return first == 'DIRECT_PLAY' || first == 'REMUX';
}

/// Whether a native client may hand the file to mpv untouched.
///
/// [strategyValues] is null when the candidates call gave no answer. That is a
/// transport failure, not a verdict: `PlayerScreen` throws before reaching this
/// on both paths that would leave it without a usable file id, so the id in
/// hand is still the route's own. Unknown therefore means direct play, because
/// the alternative is asking a server we just failed to reach to run an encode
/// first, and mpv decodes very nearly everything a transcode would produce.
///
/// Observed 2026-09-08: a 15s `StreamingCandidates` call surfaced as a failure
/// and downgraded an AV1/Opus MKV that had direct-played 22 minutes earlier
/// into a software transcode, which then died on a malformed Opus header. The
/// cautious branch produced no playback where the cheap one would have worked.
///
/// A non-Original rung still vetoes. Direct play hands the file over untouched,
/// so there is no encoder to give a height or bitrate cap to, and honouring the
/// viewer's choice means going through an HLS session instead.
///
/// Platform gating (`!kIsWeb`) is left to the caller, as above.
bool nativeDirectPlayAllowed({
  required List<String>? strategyValues,
  required bool isOriginalQuality,
}) {
  if (!isOriginalQuality) return false;
  if (strategyValues == null) return true;
  return firstStrategyAllowsDirectPlay(strategyValues);
}

/// Whether any candidate is a no-re-encode delivery (HLS_COPY or REMUX).
///
/// A bare DIRECT_PLAY without HLS_COPY/REMUX is intentionally false: on web
/// that list still plays via TRANSCODE HLS today.
bool strategiesAllowLosslessDelivery(Iterable<String> strategyValues) {
  for (final value in strategyValues) {
    if (value == 'HLS_COPY' || value == 'REMUX') return true;
  }
  return false;
}
