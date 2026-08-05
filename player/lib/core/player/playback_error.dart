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
