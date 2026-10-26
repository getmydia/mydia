/// What a subtitle search produced, and the one error type whose message a
/// viewer may see. Shared by the player's session layer and the sheet.
library;

import 'subtitle_candidate.dart';

/// Why a subtitle search or download did not happen, when the app itself is
/// the one saying so. The sheet words it in the viewer's language
/// (`AppFormatters.subtitleIssueText`); text a server sent stays a `String`
/// and is shown as it was written.
enum SubtitleIssue {
  /// Searching, on a server that is not Mydia.
  searchMydiaOnly,

  /// Downloading, from a server that is not Mydia.
  downloadMydiaOnly,

  /// Searching with only a downloaded file: there is no server to ask.
  searchOffline,

  /// Downloading with only a downloaded file.
  downloadOffline,

  /// The search request never reached the server.
  searchUnreachable,

  /// The search failed for a reason the viewer cannot act on.
  searchFailed,

  /// The download request failed.
  downloadFailed,
}

/// What a subtitle search produced.
class SubtitleSearchOutcome {
  final List<SubtitleCandidate> results;
  final List<SubtitleProviderStatus> providers;

  /// Set when the search itself failed with text the server wrote, shown as
  /// is.
  final String? error;

  /// Set when the search itself failed and the app names the reason.
  final SubtitleIssue? issue;

  const SubtitleSearchOutcome({
    required this.results,
    required this.providers,
    this.error,
    this.issue,
  });
}

/// An error whose message was written for a viewer and may be shown as-is.
///
/// The sheet never renders a raw exception object: a transport failure
/// stringifies to an `OperationException` dump, and a wiring bug to
/// whatever the framework named it. But some failures carry advice only the
/// server can give, and dropping it strands the viewer. The concrete case
/// is a candidate token expiring after fifteen minutes: the generic "try
/// again" invites re-tapping the same stale token forever, where the
/// server's own "search again" is the one instruction that works. A
/// callback throws this to opt a specific message in; everything else it
/// throws still lands on the generic copy.
class SubtitleActionException implements Exception {
  /// Shown to the viewer verbatim, so it must read as plain guidance. Null
  /// when [issue] names the reason instead.
  final String? message;

  /// The reason, when the app is the one explaining.
  final SubtitleIssue? issue;

  const SubtitleActionException(String this.message) : issue = null;
  const SubtitleActionException.issue(SubtitleIssue this.issue)
      : message = null;

  @override
  String toString() => 'SubtitleActionException: ${message ?? issue}';
}
