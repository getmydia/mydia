/// What a subtitle search produced, and the one error type whose message a
/// viewer may see. Shared by the player's session layer and the sheet.
library;

import 'subtitle_candidate.dart';

/// What a subtitle search produced.
class SubtitleSearchOutcome {
  final List<SubtitleCandidate> results;
  final List<SubtitleProviderStatus> providers;

  /// Set when the search itself failed rather than returning nothing.
  final String? error;

  const SubtitleSearchOutcome({
    required this.results,
    required this.providers,
    this.error,
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
  /// Shown to the viewer verbatim, so it must read as plain guidance.
  final String message;

  const SubtitleActionException(this.message);

  @override
  String toString() => 'SubtitleActionException: $message';
}
