import 'package:flutter/foundation.dart';

import '../../domain/sources/source_error.dart';
import '../../graphql/mutations/end_streaming_session.graphql.dart';
import '../../graphql/mutations/start_streaming_session.graphql.dart';
import '../../graphql/mutations/start_streaming_session_compat.dart';
import '../../graphql/mutations/start_streaming_session_legacy.graphql.dart';
import '../sources/mydia/root_typename.dart';
import '../../graphql/schema.graphql.dart';
import '../sources/mydia/mydia_client.dart';
import 'cast_backend.dart';

/// Starts and ends the server-side HLS sessions a bridged Chromecast route
/// needs.
///
/// `LocalProxyService` forwards `/hls/{id}/…` with `{id}` as a **streaming
/// session id**, not a file id — the p2p HLS protocol has no notion of files.
/// Local playback learns that id from `StartStreamingSession`
/// (`player_screen.dart`); a bridged cast has to do exactly the same thing
/// before it can hand a receiver a `/hls/…` URL that resolves to anything.
///
/// An interface rather than a bare function so tests can drive the cast stack
/// without a GraphQL server, and so the manager can end the session it
/// started when casting stops.
abstract class CastStreamingSessionService {
  /// Starts a session at [startPosition] and returns its id together with the
  /// offset the server actually used.
  ///
  /// The echoed value, not the requested one, is authoritative: the server
  /// clamps the request against the runtime, and a copied stream can only
  /// begin on a keyframe, which the server finds and echoes for MKV and MP4
  /// sources (MPEG-TS still echoes the requested offset). An older server
  /// omits the field, which correctly yields zero.
  ///
  /// Throws [CastBackendException] when the server refuses, so the manager's
  /// existing escalation ladder can treat it like any other route failure.
  Future<({String sessionId, Duration startOffset})> start({
    required String fileId,
    required bool transcode,
    Duration startPosition = Duration.zero,
  });

  /// Best-effort teardown. Never throws: a leaked server-side session is a
  /// far smaller problem than an exception on the stop-casting path.
  Future<void> end(String sessionId);
}

class MydiaCastStreamingSessionService implements CastStreamingSessionService {
  final MydiaClient _client;

  const MydiaCastStreamingSessionService(this._client);

  @override
  Future<({String sessionId, Duration startOffset})> start({
    required String fileId,
    required bool transcode,
    Duration startPosition = Duration.zero,
  }) async {
    final Map<String, dynamic> data;
    try {
      // The cast path sends no caps or playlist mode, so both documents take
      // the same variables. A server that rejects the full document's fields
      // is downgraded once per instance, as local playback does.
      final variables = Variables$Mutation$StartStreamingSessionLegacy(
        fileId: fileId,
        strategy: transcode
            ? Enum$StreamingStrategy.TRANSCODE
            : Enum$StreamingStrategy.HLS_COPY,
        startPosition:
            startPosition > Duration.zero ? startPosition.inSeconds : null,
      ).toJson();
      data = await _client.query(
        documentNodeMutationStartStreamingSession,
        fallback: documentNodeMutationStartStreamingSessionLegacy,
        variables: variables,
        fallbackVariables: variables,
      );
    } on SourceException catch (e) {
      throw CastBackendException(
        'Could not start a streaming session: ${e.message ?? e.viewerMessage}',
        CastFailureKind.unreachable,
      );
    }

    final session = Mutation$StartStreamingSession.fromJson(
      rootMutation(withPlaylistModeDefault(data)),
    ).startStreamingSession;

    if (session == null) {
      throw const CastBackendException(
        'The server returned no streaming session.',
        CastFailureKind.unreachable,
      );
    }

    return (
      sessionId: session.sessionId,
      startOffset: Duration(seconds: session.startPosition ?? 0),
    );
  }

  @override
  Future<void> end(String sessionId) async {
    try {
      await _client.request(
        documentNodeMutationEndStreamingSession,
        Variables$Mutation$EndStreamingSession(sessionId: sessionId).toJson(),
      );
    } catch (e) {
      debugPrint(
          '[CastStreamingSession] Ignoring end error for $sessionId: $e');
    }
  }
}
