/// User-facing subtitles for how a quality rung will be delivered.
///
/// See `docs/superpowers/specs/2026-08-09-player-quality-delivery-labels-design.md`.

const kOriginalDirectPlaySubtitle = 'Direct Play';
const kOriginalLosslessSubtitle = 'Original · no re-encoding';
const kOriginalTranscodeSubtitle = 'Original · re-encoding required';

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
String cappedRungDeliverySubtitle(int maxBitrateKbps) =>
    'Transcodes · up to $maxBitrateKbps kbps';

/// Whether native direct play is offered for this ordered candidate list.
///
/// Mirrors `PlayerScreen._canDirectPlay`: first strategy must be DIRECT_PLAY,
/// REMUX, or HLS_COPY.
bool strategiesAllowNativeDirectPlay(Iterable<String> strategyValues) {
  final iterator = strategyValues.iterator;
  if (!iterator.moveNext()) return false;
  final first = iterator.current;
  return first == 'DIRECT_PLAY' || first == 'REMUX' || first == 'HLS_COPY';
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
