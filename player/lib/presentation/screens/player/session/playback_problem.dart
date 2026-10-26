/// Why playback could not start, as data the player screen words in the
/// viewer's language.
///
/// The sessions and the screen keep this instead of a sentence. Text a server
/// sent, or a technical message from the platform, stays a `String` and is
/// shown as it was written.
library;

import '../../../../domain/sources/source_error.dart';
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

  /// The local media proxy came back on a new port and the reopen failed.
  proxyMoved,
}

/// A playback failure: one of the app's own [PlaybackIssue]s, or text from
/// somewhere else.
class PlaybackProblem {
  const PlaybackProblem(PlaybackIssue this.issue)
      : text = null,
        error = null;
  const PlaybackProblem.fromText(String this.text)
      : issue = null,
        error = null;

  /// A failure the player screen words with `AppLocalizations.sourceError`.
  const PlaybackProblem.fromError(Object this.error)
      : issue = null,
        text = null;

  final PlaybackIssue? issue;
  final String? text;
  final Object? error;

  @override
  bool operator ==(Object other) =>
      other is PlaybackProblem &&
      other.issue == issue &&
      other.text == text &&
      other.error == error;

  @override
  int get hashCode => Object.hash(issue, text, error);

  @override
  String toString() => 'PlaybackProblem(${issue ?? text ?? error})';
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
        PlaybackIssue.proxyMoved => playbackIssueProxyMoved,
      };

  String playbackProblemText(PlaybackProblem problem) {
    final issue = problem.issue;
    if (issue != null) return playbackIssueText(issue);
    final error = problem.error;
    if (error != null) return playbackFailureText(error);
    return problem.text ?? playbackErrorUnknown;
  }

  /// The text for whatever a load threw: the app's own issue, a source
  /// failure, or the exception's own text.
  String playbackFailureText(Object error) => switch (error) {
        PlaybackIssueException(:final issue) => playbackIssueText(issue),
        SourceException() => sourceError(error),
        _ => error.toString(),
      };
}
