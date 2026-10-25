/// Why a Plex, Jellyfin or Stash sign-in did not go through.
///
/// The sign-in controllers keep this in their state instead of a sentence, so
/// the text follows the viewer's language. A server's own words stay a
/// `String` and are shown as the server wrote them.
library;

import '../../../domain/sources/source_error.dart';
import '../../../l10n/l10n.dart';

enum SignInIssue {
  jellyfinAddressInvalid,
  jellyfinHttpsRequired,
  jellyfinNotJellyfin,
  jellyfinTooOld,
  jellyfinBadServerId,
  jellyfinUnreachable,
  jellyfinSignInFailed,
  jellyfinWrongCredentials,
  jellyfinBadUserId,
  plexSignInFailed,
  plexCodeExpired,
  plexNoServers,
  plexSaveFailed,
  stashAddressInvalid,
  stashHttpsRequired,
  stashKeyRejected,
  saveServerFailed,
}

/// A sign-in failure: one of the app's own [SignInIssue]s, or text the
/// server sent.
class SignInProblem {
  const SignInProblem(SignInIssue this.issue)
      : serverMessage = null,
        error = null;
  const SignInProblem.fromServer(String this.serverMessage)
      : issue = null,
        error = null;

  /// A source failure, worded with `AppLocalizations.sourceError`.
  const SignInProblem.fromError(SourceException this.error)
      : issue = null,
        serverMessage = null;

  final SignInIssue? issue;
  final String? serverMessage;
  final SourceException? error;

  @override
  bool operator ==(Object other) =>
      other is SignInProblem &&
      other.issue == issue &&
      other.serverMessage == serverMessage &&
      other.error == error;

  @override
  int get hashCode => Object.hash(issue, serverMessage, error);

  @override
  String toString() => 'SignInProblem(${issue ?? serverMessage ?? error})';
}

/// Thrown inside a sign-in controller when the app itself rejects a result.
class SignInIssueException implements Exception {
  const SignInIssueException(this.issue);

  final SignInIssue issue;
}

extension SignInProblemText on AppLocalizations {
  String signInProblemText(SignInProblem problem) {
    final issue = problem.issue;
    if (issue == null) {
      final error = problem.error;
      if (error != null) return sourceError(error);
      return problem.serverMessage ?? sourcesErrorGeneric;
    }
    return switch (issue) {
      SignInIssue.jellyfinAddressInvalid => sourcesJellyfinAddressInvalid,
      SignInIssue.jellyfinHttpsRequired => sourcesJellyfinHttpsRequired,
      SignInIssue.jellyfinNotJellyfin => sourcesJellyfinNotJellyfin,
      SignInIssue.jellyfinTooOld => sourcesJellyfinTooOld,
      SignInIssue.jellyfinBadServerId => sourcesJellyfinBadServerId,
      SignInIssue.jellyfinUnreachable => sourcesJellyfinUnreachable,
      SignInIssue.jellyfinSignInFailed => sourcesJellyfinSignInFailed,
      SignInIssue.jellyfinWrongCredentials => sourcesJellyfinWrongCredentials,
      SignInIssue.jellyfinBadUserId => sourcesJellyfinBadUserId,
      SignInIssue.plexSignInFailed => sourcesPlexSignInFailed,
      SignInIssue.plexCodeExpired => sourcesPlexCodeExpired,
      SignInIssue.plexNoServers => sourcesPlexNoServers,
      SignInIssue.plexSaveFailed => sourcesPlexSaveFailed,
      SignInIssue.stashAddressInvalid => sourcesStashAddressInvalid,
      SignInIssue.stashHttpsRequired => sourcesStashHttpsRequired,
      SignInIssue.stashKeyRejected => sourcesStashKeyRejected,
      SignInIssue.saveServerFailed => sourcesSaveServerFailed,
    };
  }
}
