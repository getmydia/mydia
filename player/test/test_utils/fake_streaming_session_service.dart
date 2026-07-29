import 'package:player/core/cast/cast_backend.dart';
import 'package:player/core/cast/cast_streaming_session_service.dart';

/// Records the server-side HLS sessions the cast stack opens and closes,
/// without a GraphQL server.
class FakeStreamingSessionService implements CastStreamingSessionService {
  final List<String> started = [];
  final List<String> ended = [];

  /// Ids handed out, in order. Sequential so a test can tell one attempt's
  /// session from another's.
  int _next = 0;

  /// When set, `start` throws with this kind instead of returning an id.
  CastFailureKind? failure;

  @override
  Future<String> start({required String fileId, required bool transcode}) async {
    final failure = this.failure;
    if (failure != null) {
      throw CastBackendException('fake session failure', failure);
    }

    final id = 'session-${++_next}${transcode ? '-transcode' : ''}';
    started.add(id);
    return id;
  }

  @override
  Future<void> end(String sessionId) async => ended.add(sessionId);

  /// Sessions started and never torn down.
  List<String> get live =>
      started.where((id) => !ended.contains(id)).toList(growable: false);
}
