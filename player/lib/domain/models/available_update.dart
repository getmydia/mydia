/// An update the user can be offered, whatever produced it.
///
/// Sealed because the two sources answer different questions. A GitHub release
/// asset knows its version, its size and its notes. The Flatpak portal knows
/// only that the remote carries a newer commit. Modelling both as one class
/// would mean inventing values for the fields the portal cannot supply.
sealed class AvailableUpdate {
  const AvailableUpdate();

  /// Where the "Release Notes" action points.
  String get releaseNotesUrl;

  /// Human-facing version, or null when the source cannot name one.
  String? get version;
}

/// A GitHub release asset for this platform.
final class AppUpdate extends AvailableUpdate {
  @override
  final String version;

  /// Direct download URL for the platform-specific asset.
  final String downloadUrl;

  /// Size of the download in bytes, if known.
  final int? downloadSize;

  @override
  final String releaseNotesUrl;

  /// Brief description / release title.
  final String releaseTitle;

  /// When the release was published.
  final DateTime publishedAt;

  const AppUpdate({
    required this.version,
    required this.downloadUrl,
    this.downloadSize,
    required this.releaseNotesUrl,
    required this.releaseTitle,
    required this.publishedAt,
  });
}

/// The Flatpak remote carries a commit newer than the installed one.
///
/// No version, no size and no notes of its own: the portal reports commits.
final class FlatpakRemoteUpdate extends AvailableUpdate {
  /// True when the newer commit is already deployed and only a restart is
  /// outstanding, which is local-commit differing from running-commit. That
  /// happens when a software centre updated the app underneath a running
  /// instance, and it means there is nothing left to download.
  final bool installedAwaitingRestart;

  @override
  final String releaseNotesUrl;

  const FlatpakRemoteUpdate({
    required this.releaseNotesUrl,
    this.installedAwaitingRestart = false,
  });

  @override
  String? get version => null;
}

/// Release notes for a Flatpak channel.
///
/// The beta remote tracks prereleases, which the /latest endpoint deliberately
/// skips, so beta gets the full list instead of a page for a release it is not
/// running.
String flatpakReleaseNotesUrl(String? branch) => branch == 'stable'
    ? 'https://github.com/getmydia/mydia/releases/latest'
    : 'https://github.com/getmydia/mydia/releases';
