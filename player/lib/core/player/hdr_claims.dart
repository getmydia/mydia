/// Which HDR formats each platform tells the server it renders correctly.
///
/// The server direct-plays an HDR file only to a client sharing a token with
/// it, and tonemaps to SDR otherwise, so a claim here is a promise that the
/// picture is right. Tokens are the server's: `dolby_vision`, `hdr10+`,
/// `hdr10`, `hlg`. The legacy `hdr10plus` is still accepted by the server but
/// must not be sent.
library;

/// Desktop and iOS: mpv's `gpu` output renders PQ and HLG transfer curves
/// correctly (HDR10+ plays as HDR10 with its dynamic metadata ignored).
/// Dolby Vision is not claimed: mpv only reaches the HDR10 base layer of
/// profile 8 and renders profile 5 with wrong colours.
const List<String> nativeHdrFormats = ['hdr10+', 'hdr10', 'hlg'];

/// Android: unverified pending the on-device check (Task 7), so nothing is
/// claimed. An empty list is the safe default because the server then
/// tonemaps HDR to SDR, which looks right everywhere, where a wrong claim
/// would hand a panel an untonemapped HDR stream it may render washed out.
const List<String> androidHdrFormats = [];

/// Web: the browser can only show HDR when the display is HDR capable
/// ([highDynamicRange], `(dynamic-range: high)`) and the decoder reports the
/// transfer function as supported ([pq] for HDR10 and HDR10+, [hlg] for HLG).
List<String> webHdrFormats({
  required bool highDynamicRange,
  required bool pq,
  required bool hlg,
}) {
  if (!highDynamicRange) return const [];
  return [
    if (pq) ...['hdr10+', 'hdr10'],
    if (hlg) 'hlg'
  ];
}
