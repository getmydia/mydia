import 'package:flutter/foundation.dart';
import 'package:graphql_flutter/graphql_flutter.dart';

import '../../graphql/mutations/end_streaming_session.graphql.dart';
import '../../graphql/mutations/start_streaming_session.graphql.dart';
import '../../graphql/schema.graphql.dart';
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
  /// Starts a session and returns its id.
  ///
  /// Throws [CastBackendException] when the server refuses, so the manager's
  /// existing escalation ladder can treat it like any other route failure.
  Future<String> start({required String fileId, required bool transcode});

  /// Best-effort teardown. Never throws: a leaked server-side session is a
  /// far smaller problem than an exception on the stop-casting path.
  Future<void> end(String sessionId);
}

class GraphqlCastStreamingSessionService implements CastStreamingSessionService {
  final GraphQLClient _client;

  const GraphqlCastStreamingSessionService(this._client);

  @override
  Future<String> start({required String fileId, required bool transcode}) async {
    final result = await _client.mutate(MutationOptions(
      document: documentNodeMutationStartStreamingSession,
      variables: Variables$Mutation$StartStreamingSession(
        fileId: fileId,
        strategy: transcode
            ? Enum$StreamingStrategy.TRANSCODE
            : Enum$StreamingStrategy.HLS_COPY,
      ).toJson(),
    ));

    if (result.hasException) {
      throw CastBackendException(
        'Could not start a streaming session: ${result.exception}',
        CastFailureKind.unreachable,
      );
    }

    final data = result.data;
    final session = data == null
        ? null
        : Mutation$StartStreamingSession.fromJson(data).startStreamingSession;

    if (session == null) {
      throw const CastBackendException(
        'The server returned no streaming session.',
        CastFailureKind.unreachable,
      );
    }

    return session.sessionId;
  }

  @override
  Future<void> end(String sessionId) async {
    try {
      await _client.mutate(MutationOptions(
        document: documentNodeMutationEndStreamingSession,
        variables:
            Variables$Mutation$EndStreamingSession(sessionId: sessionId)
                .toJson(),
      ));
    } catch (e) {
      debugPrint('[CastStreamingSession] Ignoring end error for $sessionId: $e');
    }
  }
}
