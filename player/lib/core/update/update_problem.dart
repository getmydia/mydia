/// Why an update could not be checked for, installed or switched, as data the
/// settings screen words in the viewer's language.
///
/// The backends and the notifier keep this instead of a sentence. Technical
/// text from the platform or the portal stays a `String` in [detail] and is
/// shown as it was written.
library;

enum UpdateIssue {
  /// Android: the install-unknown-apps permission is not granted.
  installPermissionDenied,

  /// Android: the viewer came back from settings without granting it.
  installPermissionStillDenied,

  /// This platform has no installer.
  installerUnavailable,

  /// The new build asks for permissions the installed one lacks.
  needsNewPermissions,

  /// The Flatpak portal could not be reached.
  portalUnreachable,

  /// The portal ended without a result.
  noResult,

  /// The failure carried no text of its own.
  updateFailed,

  /// The platform's installer failed; [UpdateProblem.detail] says how.
  installFailed,

  /// The update check failed; [UpdateProblem.detail] says how.
  checkFailed,

  /// The chosen track could not be saved; [UpdateProblem.detail] may say why.
  saveChoiceFailed,

  /// macOS would not save the chosen track.
  saveChoiceFailedMacos,

  /// The downloaded archive does not match its published checksum.
  checksumMismatch,

  /// Unpacking the archive failed; [UpdateProblem.detail] is the tool's text.
  extractFailed,

  /// Copying the new files over the install failed; the detail is the tool's
  /// text.
  copyFailed,

  /// Marking the new AppImage executable failed; the detail is the tool's
  /// text.
  chmodFailed,

  /// The download is not an AppImage (truncated, or an error page).
  notAnAppImage,
}

class UpdateProblem {
  const UpdateProblem(this.issue, {this.detail}) : text = null;

  /// Text from the platform, shown verbatim.
  const UpdateProblem.text(String this.text)
      : issue = null,
        detail = null;

  final UpdateIssue? issue;

  /// The platform's own words for [issue], when it gave any.
  final String? detail;

  /// Verbatim text, when no [issue] applies.
  final String? text;

  @override
  bool operator ==(Object other) =>
      other is UpdateProblem &&
      other.issue == issue &&
      other.detail == detail &&
      other.text == text;

  @override
  int get hashCode => Object.hash(issue, detail, text);

  @override
  String toString() => 'UpdateProblem(${issue ?? text}, $detail)';
}

/// Thrown by an updater when a step fails for a reason the app can name. The
/// backend turns it into an `UpdateFailed` carrying [problem].
class UpdateStepFailed implements Exception {
  const UpdateStepFailed(this.problem);

  final UpdateProblem problem;

  @override
  String toString() => 'UpdateStepFailed($problem)';
}
