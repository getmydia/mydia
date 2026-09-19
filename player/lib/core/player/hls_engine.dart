/// Which HLS engine plays a streamed source in the browser.
///
/// media_kit picks between two on web (`_isHLS` in
/// `media_kit/lib/src/player/web/player/real.dart`): hls.js, or the browser's
/// own HLS engine reached by assigning `element.src`. It picks the browser's
/// whenever `canPlayType('application/vnd.apple.mpegurl')` answers non-empty,
/// which every WebKit browser does and desktop Chromium has since 143.
///
/// That choice does not survive contact with a Mydia session. The playlist a
/// `:full` session publishes lists every segment of the file up front, most of
/// which no encoder has reached yet; a request for one of those is answered
/// `503` with `Retry-After` (see `hls_controller.ex`), and a resume relocates
/// the encoder mid-flight so segments arrive from more than one FFmpeg run.
/// hls.js and mpv retry and tolerate all of that, which is what the server was
/// built against. A browser's own engine does not: measured on 2026-09-19, a
/// session resumed mid-file froze within ~10s and never recovered, in iOS
/// Safari against production and in Chromium's native HLS locally, while the
/// same session played straight through once hls.js was in the path.
///
/// So this asks media_kit the only question it acts on, and answers it
/// differently: [prepareHlsEngine] hides the browser's HLS claim, but only
/// while hls.js can actually run. Where it cannot — iOS Safari below 17.1 has
/// neither `MediaSource` nor `ManagedMediaSource` — nothing is hidden and the
/// browser's engine stays the only path, exactly as before.
///
/// See `codec_support.dart` for the detection this pairs with, and
/// `player/docs/playback.md` for where it sits in the playback story.
library;

import 'hls_engine_stub.dart' if (dart.library.js_interop) 'hls_engine_web.dart'
    as platform;

/// The vendored hls.js, relative to the document base (`/player/`).
///
/// media_kit bundles hls.js 1.4.10, which predates `ManagedMediaSource` and so
/// reports itself unsupported on iPhone — the one platform this fix is for.
/// `web/hls/` carries a current build instead, and [prepareHlsEngine] loads it
/// before media_kit can load its own.
const String kVendoredHlsJsUrl = 'hls/hls.min.js';

/// The content types a browser answers for HLS, lower-cased and without
/// parameters.
const Set<String> kHlsContentTypes = {
  'application/vnd.apple.mpegurl',
  'application/x-mpegurl',
  'audio/mpegurl',
  'audio/x-mpegurl',
  'video/mpegurl',
  'video/x-mpegurl',
};

/// Whether `canPlayType(contentType)` should answer "unsupported" so media_kit
/// reaches for hls.js.
///
/// Pure, and the whole decision: [hlsJsUsable] is false whenever hls.js is
/// missing or cannot run in this browser, and then nothing is hidden — a
/// browser with no working engine at all is worse than one whose engine copes
/// badly. Anything that is not an HLS type is never touched, so progressive
/// MP4, WebM and audio files keep the browser's real answer.
bool hidesNativeHls(String contentType, {required bool hlsJsUsable}) {
  if (!hlsJsUsable) return false;
  final type = contentType.split(';').first.trim().toLowerCase();
  return kHlsContentTypes.contains(type);
}

/// Loads hls.js and puts it in media_kit's path, once per page.
///
/// Must be awaited before the first `Player` is constructed: media_kit reads
/// `canPlayType` when it opens a source, and the engine it picks there is the
/// one that session keeps.
///
/// Never throws. A failure to load leaves the browser's own engine in place,
/// which is what shipped before this existed. A no-op off the web.
Future<void> prepareHlsEngine() => platform.prepareHlsEngine();
