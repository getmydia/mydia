/// Why playback could not start, as data the player screen words in the
/// viewer's language.
///
/// The sessions and the screen keep this instead of a sentence. Text a server
/// sent, or a technical message from the platform, stays a `String` and is
/// shown as it was written.
library;

import '../../../../l10n/l10n.dart';

enum PlaybackIssue {
  /// The item has no file the server can play.
  noPlayableFile,

  /// The server asked for a plain address and gave none.
  serverUrlMissing,

  /// The server cannot be reached over the peer-to-peer connection.
  p2pUnsupported,

  /// The server could not be reached to pick a file for the title.
  noFileOffered,

  /// Offline with nothing downloaded for this title.
  notAvailableOffline,

  /// The download record points at a file that is gone.
  downloadMissing,

  /// This browser has no way to play streamed video.
  browserUnsupported,
}

/// A playback failure: one of the app's own [PlaybackIssue]s, or text from
/// somewhere else.
class PlaybackProblem {
  const PlaybackProblem(PlaybackIssue this.issue) : text = null;
  const PlaybackProblem.fromText(String this.text) : issue = null;

  final PlaybackIssue? issue;
  final String? text;

  @override
  bool operator ==(Object other) =>
      other is PlaybackProblem && other.issue == issue && other.text == text;

  @override
  int get hashCode => Object.hash(issue, text);

  @override
  String toString() => 'PlaybackProblem(${issue ?? text})';
}

/// Thrown inside the player screen's open path when the app itself knows why
/// playback cannot start. The surrounding catch words it; any other
/// exception is shown as its own text.
class PlaybackIssueException implements Exception {
  const PlaybackIssueException(this.issue);

  final PlaybackIssue issue;

  @override
  String toString() => 'PlaybackIssueException($issue)';
}

extension PlaybackProblemText on AppLocalizations {
  String playbackIssueText(PlaybackIssue issue) => switch (issue) {
        PlaybackIssue.noPlayableFile => playbackIssueNoPlayableFile,
        PlaybackIssue.serverUrlMissing => playbackIssueServerUrlMissing,
        PlaybackIssue.p2pUnsupported => playbackIssueP2pUnsupported,
        PlaybackIssue.noFileOffered => playbackIssueNoFileOffered,
        PlaybackIssue.notAvailableOffline => playbackIssueNotAvailableOffline,
        PlaybackIssue.downloadMissing => playbackIssueDownloadMissing,
        PlaybackIssue.browserUnsupported => playbackIssueBrowserUnsupported,
      };

  String playbackProblemText(PlaybackProblem problem) {
    final issue = problem.issue;
    if (issue != null) return playbackIssueText(issue);
    return problem.text ?? playbackErrorUnknown;
  }
}
