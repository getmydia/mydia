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
