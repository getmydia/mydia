/// Maps media_kit's view of a stream onto the real media timeline.
///
/// Two facts make the player's own numbers untrustworthy on an HLS stream:
///
/// 1. Mydia's HLS playlists are live-style with no `EXT-X-ENDLIST`, so early in
///    a session the player reports a small, still-growing duration rather than
///    the real runtime.
/// 2. When a session is started at a resume offset (FFmpeg `-ss`), the playlist
///    timestamps begin near zero, so the player's position 0 is really
///    [startOffset] into the media.
///
/// Both corrections belong together: a consumer that applies one without the
/// other reports a wrong position or a wrong percentage. Every duration and
/// position shown to the user, persisted as progress, or handed to a cast
/// receiver must go through this type.
class StreamTimeline {
  /// The real media position corresponding to player position zero.
  final Duration startOffset;

  /// The real full runtime, when the server has told us. Null when unknown.
  final Duration? totalDuration;

  const StreamTimeline({
    this.startOffset = Duration.zero,
    this.totalDuration,
  });

  /// A stream that starts at the beginning with an unknown runtime. Correct for
  /// direct play and offline playback, where the player holds the whole file
  /// and its own numbers are already right.
  static const StreamTimeline zero = StreamTimeline();

  /// Converts a player-reported position into a real media position.
  Duration toReal(Duration playerPosition) => startOffset + playerPosition;

  /// Converts a real media position into a player-relative position.
  ///
  /// Clamps at zero: a real position before [startOffset] is not present in
  /// this stream at all, and the caller should have restarted the session.
  Duration toPlayer(Duration realPosition) {
    final relative = realPosition - startOffset;
    return relative.isNegative ? Duration.zero : relative;
  }

  /// The real full runtime, preferring the server's figure.
  ///
  /// Falls back to [startOffset] plus the player's duration, because with an
  /// offset the player only sees the remainder of the media.
  Duration resolveDuration(Duration playerDuration) {
    final total = totalDuration;
    if (total != null && total > Duration.zero) return total;
    return startOffset + playerDuration;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StreamTimeline &&
          other.startOffset == startOffset &&
          other.totalDuration == totalDuration;

  @override
  int get hashCode => Object.hash(startOffset, totalDuration);

  @override
  String toString() =>
      'StreamTimeline(startOffset: $startOffset, totalDuration: $totalDuration)';
}
