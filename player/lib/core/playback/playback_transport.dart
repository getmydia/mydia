/// What the player screen asks of whatever turns a plan into bytes: Mydia's
/// streaming sessions, or a third-party server's URLs.
///
/// Not called `StreamController`: `dart:async` owns that name, and the
/// player screen imports it.
library;

import 'playback_controller.dart' show PlaybackSource;
import 'playback_plan.dart';
import 'stream_urls.dart' show ResolvedSource;

abstract interface class PlaybackTransport {
  /// The server session behind the current source. Null for direct play.
  String? get sessionId;

  /// True for the whole of [replaceSource], including while it awaits.
  bool get switching;

  /// A file inside the live session, reached as its playlist is. Null when
  /// there is none.
  ResolvedSource? sessionFile(String name);

  Future<PlaybackSource> open(
    PlaybackPlan plan, {
    required String fileId,
    required Duration startAt,
    Duration? totalDuration,
    void Function(String message)? onProgress,
  });

  Future<PlaybackSource> replaceSource(
    PlaybackPlan plan, {
    required String fileId,
    required Duration realPosition,
    Duration? totalDuration,
    required Future<Stream<Duration>> Function(PlaybackSource source) attach,
    void Function(String message)? onProgress,
  });

  /// Ends every session this transport owns. Safe to call more than once.
  Future<void> endSession();
}
