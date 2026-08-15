/// Version floors this player declares about the servers it connects to.
///
/// The mirror of these lives server-side in `lib/mydia/compatibility.ex`, which
/// declares the oldest *player* a server works with. The two are different
/// facts and neither derives from the other: a server cannot know what a future
/// player needs, and a player cannot know what a future server drops.
///
/// This direction matters more often in practice. Mobile and desktop players
/// update themselves from GitHub releases while a self-hosted server stays on
/// whatever the operator last pulled, so "player newer than server" is the
/// common mismatch, and an old server has no way to warn about it.
///
/// ## When to bump
///
/// Bump [minServerVersion] to the release you are shipping when the player
/// starts depending on something older servers do not provide: a GraphQL field
/// added in that release, a changed streaming contract, a new endpoint.
///
/// Bump [recommendedServerVersion] when an older server still works but the
/// experience is degraded.
///
/// Do not bump either for routine releases. A floor that moves every release
/// trains operators to ignore the banner.
///
/// ## Last changed
///
/// - 0.9.0: initial baseline, set to the release this mechanism shipped in.
class Compatibility {
  const Compatibility._();

  /// The oldest server version this player works with.
  static const minServerVersion = '0.9.0';

  /// The oldest server version this player would rather talk to.
  static const recommendedServerVersion = '0.9.0';
}
