/// Which release cadence this installation follows.
///
/// The names are user facing. The third track builds from the master branch,
/// but "master" means nothing to someone who does not know the repository, so
/// it is Dev everywhere the user can see it. The wire names are what the feed
/// and the stored preference use, and they must not drift from the keys in
/// releases.json.
enum UpdateTrack {
  stable,
  beta,
  dev;

  /// The key this track has in releases.json and in stored settings.
  String get wireName => switch (this) {
        UpdateTrack.stable => 'stable',
        UpdateTrack.beta => 'beta',
        UpdateTrack.dev => 'dev',
      };

  String get label => switch (this) {
        UpdateTrack.stable => 'Stable',
        UpdateTrack.beta => 'Beta',
        UpdateTrack.dev => 'Dev',
      };

  String get description => switch (this) {
        UpdateTrack.stable => 'Released builds. The default.',
        UpdateTrack.beta =>
          'Prerelease builds, a few weeks ahead of stable and less tested.',
        UpdateTrack.dev =>
          'Builds straight from development, published when a maintainer asks '
              'for one. Expect rough edges.',
      };

  /// Null for an unknown name rather than a throw, so a preference written by
  /// a newer build cannot stop an older one from starting.
  static UpdateTrack? fromWireName(String? name) {
    for (final track in UpdateTrack.values) {
      if (track.wireName == name) return track;
    }
    return null;
  }
}
