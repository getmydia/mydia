/// [PlaybackSession] over Mydia's GraphQL API.
///
/// Every method sends the document, variables and fetch policy the player
/// screen sent before the move. Changing any of them changes playback.
library;

import 'package:flutter/foundation.dart';
import 'package:graphql_flutter/graphql_flutter.dart';

import '../../../../core/playback/candidates_from_graphql.dart';
import '../../../../graphql/queries/streaming_candidates.graphql.dart';
import 'playback_session.dart';
import 'playback_session_types.dart';

class MydiaPlaybackSession implements PlaybackSession {
  MydiaPlaybackSession({
    required GraphQLClient? Function() client,
    required Future<GraphQLClient> Function() awaitClient,
    required PlaybackTarget Function() target,
  })  : _client = client,
        _awaitClient = awaitClient,
        _target = target;

  /// The screen's current client, null until the provider first resolves.
  final GraphQLClient? Function() _client;

  /// Waits for the client provider, for calls the screen made that way.
  // ignore: unused_field
  final Future<GraphQLClient> Function() _awaitClient;
  final PlaybackTarget Function() _target;

  GraphQLClient _requireClient() =>
      _client() ?? (throw StateError('no GraphQL client is available'));

  /// Fetch streaming candidates from the server via GraphQL.
  ///
  /// `networkOnly` is load-bearing. The primary call is keyed by the specific
  /// file the user selected, not by content id. When the server rejects that
  /// file id (e.g. a quality upgrade trashed it), the screen re-asks by media
  /// item and plays whatever the server ranks instead. That self-heal only
  /// works if the rejection is observable: a warm cache entry recorded before
  /// the file was trashed still holds a successful response, so serving it
  /// would keep `serverRejected` false and the self-heal would never fire. On
  /// the fallback paths (the offline sentinel, and the self-heal) the id used
  /// for playback comes from this response, so a stale cached response would
  /// also feed a dead file straight into playback.
  ///
  /// `cacheAndNetwork` is not the fix: on a one-shot `client.query()` it
  /// returns the cached result and discards the network one, which is the
  /// defect `core/graphql/watch/query_watcher.dart` documents. Nothing is
  /// lost by going to the network: every path that reaches here needs the
  /// server to serve a single byte.
  ///
  /// `serverRejected` says *why* a call failed, so the caller knows whether
  /// it is safe to retry against a different id. The server answers an
  /// unknown id with a GraphQL error (e.g. "file not found"), so the
  /// exception carries non-empty `graphqlErrors` and a null `linkException`.
  /// A transport failure looks the opposite: no `graphqlErrors`, a non-null
  /// `linkException`. Only the former means "this id doesn't exist"; the
  /// latter means "we don't know".
  @override
  Future<CandidatesFetch> candidates(CandidateScope scope) async {
    final target = _target();
    final (contentType, id) = switch (scope) {
      CandidateScope.file => ('file', target.fileId),
      CandidateScope.item => (
          target.mediaType == 'movie' ? 'movie' : 'episode',
          target.mediaId,
        ),
    };
    try {
      final result = await _requireClient().query(
        QueryOptions(
          document: documentNodeQueryStreamingCandidates,
          variables: Variables$Query$StreamingCandidates(
            contentType: contentType,
            id: id,
          ).toJson(),
          fetchPolicy: FetchPolicy.networkOnly,
        ),
      );

      if (result.hasException) {
        debugPrint(
            '[PlayerScreen] Failed to fetch candidates: ${result.exception}');
        final exception = result.exception;
        final serverRejected = exception != null &&
            exception.graphqlErrors.isNotEmpty &&
            exception.linkException == null;
        return (offer: null, serverRejected: serverRejected);
      }

      final data =
          Query$StreamingCandidates.fromJson(result.data!).streamingCandidates;
      if (data == null) return (offer: null, serverRejected: false);
      return (
        offer: PlaybackOffer(
          fileId: data.fileId,
          candidates: candidateStrategiesFrom(data.candidates),
          durationSeconds: data.metadata.duration,
          height: data.metadata.height,
          bitrateBps: data.metadata.bitrate,
          preferredAudioLanguages: data.metadata.preferredAudioLanguages,
        ),
        serverRejected: false,
      );
    } catch (e) {
      debugPrint('[PlayerScreen] Error fetching streaming candidates: $e');
      return (offer: null, serverRejected: false);
    }
  }
}
