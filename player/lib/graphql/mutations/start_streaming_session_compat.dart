/// Defaults a `startStreamingSession` JSON payload's `playlistMode` to
/// `WINDOW` when the key is absent, before it reaches the generated parser.
///
/// The schema declares the field non-null (`playlistMode: PlaylistMode!`),
/// so the generated `fromJson` has no null-safe path for "absent" -- it
/// force-casts the raw value and throws `type 'Null' is not a subtype of
/// type 'String'`. A server too old to know about `playlistMode` never sends
/// the key at all -- neither a server that predates the field entirely, nor
/// one that only answered through `start_streaming_session_legacy.graphql`,
/// which never selects it -- and both of those are exactly a server that
/// predates full-playlist support, i.e. exactly what `WINDOW` already means.
///
/// Shared by every caller that parses this mutation's result --
/// `PlayerScreen`'s own session start and `GraphqlCastStreamingSessionService`
/// -- so this compatibility handling lives in one place instead of being
/// re-derived, or forgotten, at each call site.
Map<String, dynamic> withPlaylistModeDefault(Map<String, dynamic> data) {
  final rawSession = data['startStreamingSession'];
  if (rawSession is! Map<String, dynamic> ||
      rawSession.containsKey('playlistMode')) {
    return data;
  }
  return {
    ...data,
    'startStreamingSession': {...rawSession, 'playlistMode': 'WINDOW'},
  };
}
