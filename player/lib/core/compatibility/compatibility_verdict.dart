import '../update/version_comparator.dart';
import 'compatibility.dart';

/// What a server told us about itself and the players it supports.
class ServerCompatibilityInfo {
  /// The server's own version, e.g. "0.9.0" or "0.9.0*abc1234" on a master build.
  final String version;

  /// The oldest player version the server works with.
  final String minPlayerVersion;

  /// The oldest player version the server would rather talk to.
  final String recommendedPlayerVersion;

  /// Whether the server rejected the `serverCompatibility` query as an unknown
  /// field, so it predates 0.14.0, the release that added the query.
  final bool predatesQuery;

  const ServerCompatibilityInfo({
    required this.version,
    required this.minPlayerVersion,
    required this.recommendedPlayerVersion,
  }) : predatesQuery = false;

  /// A server too old to answer the query. Its versions are unknown.
  const ServerCompatibilityInfo.predatesQuery()
      : version = '',
        minPlayerVersion = '',
        recommendedPlayerVersion = '',
        predatesQuery = true;
}

/// Whether this player and the connected server can work together.
enum CompatibilityVerdict {
  /// Both sides clear each other's floors.
  compatible,

  /// The player is below the server's recommended floor.
  playerUpdateRecommended,

  /// The player is below the server's required floor.
  playerUpdateRequired,

  /// The server is below the player's recommended floor.
  serverUpdateRecommended,

  /// The server is below the player's required floor.
  serverUpdateRequired,

  /// We could not tell: the query failed or a version string would not parse.
  /// Renders nothing.
  unknown;

  /// Whether this verdict warrants a banner at all.
  bool get showsBanner =>
      this != CompatibilityVerdict.compatible &&
      this != CompatibilityVerdict.unknown;

  /// Whether the mismatch is a hard floor rather than a nudge.
  bool get isRequired =>
      this == CompatibilityVerdict.playerUpdateRequired ||
      this == CompatibilityVerdict.serverUpdateRequired;

  /// Whether the user may dismiss the banner. Required verdicts may not be.
  bool get isDismissible => showsBanner && !isRequired;

  /// Whether the player, rather than the server, is the side that is behind.
  bool get isPlayerBehind =>
      this == CompatibilityVerdict.playerUpdateRequired ||
      this == CompatibilityVerdict.playerUpdateRecommended;
}

/// Decides whether this player and [server] can work together.
///
/// Fails open: any unparseable version, or a null [server] (which is what a
/// failed query produces), yields [CompatibilityVerdict.unknown] and renders
/// nothing. The one exception is a server that rejected the query itself, which
/// is below the floor by construction. A bug here must degrade to silence,
/// never to a nag.
///
/// Evaluation order is the tie-break rule: required outranks recommended, and
/// within a tier the player side wins, because the person holding the phone can
/// act on that message themselves.
CompatibilityVerdict evaluateCompatibility({
  required String playerVersion,
  required ServerCompatibilityInfo? server,
}) {
  if (server == null) return CompatibilityVerdict.unknown;

  // The query only exists from 0.14.0, below the 0.15.0 floor.
  if (server.predatesQuery) return CompatibilityVerdict.serverUpdateRequired;

  // A build with no version stamped reports "0.0.0-dev": mix.exs falls back to
  // it whenever BUILD_VERSION is unset, which covers every local dev server,
  // every self-built image, and the published :master image, since ci-docker.yml
  // does not pass BUILD_VERSION. That is an unversioned build, not an ancient
  // one, so it gets the same unknown verdict as a version that will not parse.
  // Without this, 0.0.0 sorts below every floor and raises a permanent
  // non-dismissible "your server is out of date" banner against a server
  // running the newest code in the repo.
  if (VersionComparator.compareCore(server.version, '0.0.0') == 0 ||
      VersionComparator.compareCore(playerVersion, '0.0.0') == 0) {
    return CompatibilityVerdict.unknown;
  }

  final playerVsMin =
      VersionComparator.compareCore(playerVersion, server.minPlayerVersion);
  final playerVsRecommended = VersionComparator.compareCore(
      playerVersion, server.recommendedPlayerVersion);
  final serverVsMin = VersionComparator.compareCore(
      server.version, Compatibility.minServerVersion);
  final serverVsRecommended = VersionComparator.compareCore(
      server.version, Compatibility.recommendedServerVersion);

  final anyUnparseable = playerVsMin == null ||
      playerVsRecommended == null ||
      serverVsMin == null ||
      serverVsRecommended == null;
  if (anyUnparseable) return CompatibilityVerdict.unknown;

  if (playerVsMin < 0) return CompatibilityVerdict.playerUpdateRequired;
  if (serverVsMin < 0) return CompatibilityVerdict.serverUpdateRequired;
  if (playerVsRecommended < 0) {
    return CompatibilityVerdict.playerUpdateRecommended;
  }
  if (serverVsRecommended < 0) {
    return CompatibilityVerdict.serverUpdateRecommended;
  }

  return CompatibilityVerdict.compatible;
}
