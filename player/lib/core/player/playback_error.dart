/// Turning a media_kit failure into something a viewer can act on.
///
/// Extracted as a free function so it can be unit-tested without a widget
/// tree, following the same pattern as `shouldOfferResume` in
/// [resume_plan.dart].
library;

/// mpv's wording when a source cannot be resolved at all.
///
/// This is what a stream that 404s looks like from the player's side: the
/// local p2p proxy forwards the server's status, and mpv reports only that the
/// URL would not open. The underlying cause is almost always that the bytes
/// are no longer where the client was told they would be — a file replaced by
/// a quality upgrade, deleted by hand, or an HLS session that has since been
/// reaped.
const String _openFailure = 'failed to open';

/// How each engine words a `play()` the browser refused to start.
///
/// On web `Player.play()` is `HTMLVideoElement.play()`, and a browser will
/// reject that promise with a `NotAllowedError` whenever the page has no live
/// user activation to spend. media_kit hands us only the `DOMException`'s
/// `message` — never its `name` — so the wording is all there is to match on.
///
/// Matched on the stable middle of each sentence rather than the whole of it:
/// Chromium appends a help URL that has changed before, and matching
/// `interact with the document` rather than `didn't interact` sidesteps
/// whether the apostrophe arrives straight or curly.
const List<String> _autoplayRefusals = [
  // WebKit's generic NotAllowedError description, and Firefox's near-identical
  // wording ("The play method is not allowed by the user agent...").
  'not allowed by the user agent',
  // Chromium: "play() failed because the user didn't interact with the
  // document first. https://goo.gl/xX8pDD"
  'interact with the document',
];

/// Whether [raw] is a browser refusing to *start* playback, not a failure to
/// load it.
///
/// This is the one media_kit error that is not a failure at all: the media is
/// open, the manifest is attached and the element is ready — the browser is
/// simply declining to begin without a user gesture to charge it to. Treating
/// it like every other error is what put a "Failed to load video" screen in
/// front of a video that was already sitting there ready to play.
///
/// Matches on wording alone and knows nothing about the platform. These are
/// browser strings that mpv has no reason to produce, but the caller gates on
/// `kIsWeb` anyway rather than leave a native build's error text to be judged
/// against a browser's vocabulary.
bool autoplayBlocked(String raw) {
  final lower = raw.toLowerCase();
  return _autoplayRefusals.any(lower.contains);
}

/// A viewer-facing sentence for a raw media_kit error string.
///
/// Falls through to the raw text for anything unrecognised. Showing an ugly
/// mpv string is worse than showing a clean one, but it is far better than the
/// alternative this function exists to replace, which was showing nothing at
/// all and leaving a black screen running a timeline.
String playbackErrorMessage(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) {
    return 'Playback failed for an unknown reason.';
  }

  if (trimmed.toLowerCase().contains(_openFailure)) {
    return 'Could not open this stream. The file may have been moved, '
        'replaced, or deleted on the server. Try playing it again.';
  }

  return 'Playback failed: $trimmed';
}
