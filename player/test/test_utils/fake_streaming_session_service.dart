import 'package:player/core/cast/cast_backend.dart';
import 'package:player/core/cast/cast_streaming_session_service.dart';

/// Records the server-side HLS sessions the cast stack opens and closes,
/// without a GraphQL server.
class FakeStreamingSessionService implements CastStreamingSessionService {
  final List<String> started = [];
  final List<String> ended = [];

  /// The file ids sessions were asked for, in order, so a test can prove a
  /// route targeted the media it meant to. The URL no longer carries the file
  /// id on a session-addressed HLS route, so this is the only place it shows.
  final List<String> requestedFileIds = [];

  /// Ids handed out, in order. Sequential so a test can tell one attempt's
  /// session from another's.
  int _next = 0;

  /// When set, `start` throws with this kind instead of returning an id.
  CastFailureKind? failure;

  /// The offset the fake server reports back. Tests that care about the
  /// echoed-not-requested distinction set this to something other than
  /// [requestedStart].
  Duration echoedStartOffset = Duration.zero;
  Duration? requestedStart;

  @override
  Future<({String sessionId, Duration startOffset})> start({
    required String fileId,
    required bool transcode,
    Duration startPosition = Duration.zero,
  }) async {
    final failure = this.failure;
    if (failure != null) {
      throw CastBackendException('fake session failure', failure);
    }

    requestedStart = startPosition;
    requestedFileIds.add(fileId);
    final id = 'session-${++_next}${transcode ? '-transcode' : ''}';
    started.add(id);
    return (sessionId: id, startOffset: echoedStartOffset);
  }

  @override
  Future<void> end(String sessionId) async => ended.add(sessionId);

  /// Sessions started and never torn down.
  List<String> get live =>
      started.where((id) => !ended.contains(id)).toList(growable: false);
}
