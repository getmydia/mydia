/// Quality ceiling for sessions whose bytes cross our relay.
///
/// A browser cannot hole-punch, so a web session never leaves the relay and
/// every byte is bandwidth we pay for. Capping bounds the cost per stream. It
/// also sidesteps browser codec gaps, since HEVC and AC3 do not play in most
/// browsers and would force a transcode regardless.
const int kWebMaxBitrateKbps = 3000;
const int kWebMaxHeight = 720;

/// Caps for a streaming session, or nulls when no cap applies.
///
/// [relayed] is false for the instance-hosted `/player` build, which reaches
/// its own origin over HTTP and costs us nothing.
({int? maxBitrate, int? maxHeight}) webSessionLimits({required bool relayed}) {
  if (!relayed) {
    return (maxBitrate: null, maxHeight: null);
  }
  return (maxBitrate: kWebMaxBitrateKbps, maxHeight: kWebMaxHeight);
}

/// The more restrictive of a viewer's own request and a platform ceiling.
///
/// Null means "no ceiling" for either side, so the result is null only when
/// both are: one side missing falls back to whichever is set, and two
/// present values take the smaller. Used to combine a viewer's own quality
/// pick with [webSessionLimits], so a relay session can never exceed the cap
/// while a viewer's own, tighter choice still survives unmodified.
int? tighterCap(int? requested, int? ceiling) {
  if (requested == null) return ceiling;
  if (ceiling == null) return requested;
  return requested < ceiling ? requested : ceiling;
}
