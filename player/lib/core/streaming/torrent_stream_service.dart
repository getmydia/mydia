import 'package:graphql_flutter/graphql_flutter.dart';
import '../../domain/models/torrent_candidate.dart';
import '../../graphql/queries/torrent_candidates.graphql.dart';
import '../../graphql/mutations/start_torrent_session.graphql.dart';
import '../../graphql/mutations/end_torrent_session.graphql.dart';

class TorrentStreamService {
  final GraphQLClient _client;

  TorrentStreamService(this._client);

  Future<List<TorrentCandidate>> getCandidates(
      String contentType, String id) async {
    final result = await _client.query(
      QueryOptions(
        document: documentNodeQueryTorrentCandidates,
        variables: Variables$Query$TorrentCandidates(
          contentType: contentType,
          id: id,
        ).toJson(),
        fetchPolicy: FetchPolicy.networkOnly,
      ),
    );

    if (result.hasException) {
      throw result.exception!;
    }

    final parsed = Query$TorrentCandidates.fromJson(result.data!);
    final candidates = parsed.torrentCandidates ?? [];
    return candidates
        .whereType<Query$TorrentCandidates$torrentCandidates>()
        .map(
          (c) => TorrentCandidate(
            title: c.title,
            size: c.size,
            seeders: c.seeders,
            leechers: c.leechers,
            magnetLink: c.magnetLink,
            indexer: c.indexer,
            quality: c.quality,
            healthScore: c.healthScore,
          ),
        )
        .toList();
  }

  Future<Map<String, String>> startSession({
    required String magnetLink,
    required String releaseTitle,
    String? mediaItemId,
    String? episodeId,
  }) async {
    final result = await _client.mutate(
      MutationOptions(
        document: documentNodeMutationStartTorrentSession,
        variables: Variables$Mutation$StartTorrentSession(
          magnetLink: magnetLink,
          releaseTitle: releaseTitle,
          mediaItemId: mediaItemId,
          episodeId: episodeId,
        ).toJson(),
      ),
    );

    if (result.hasException) {
      throw result.exception!;
    }

    final parsed = Mutation$StartTorrentSession.fromJson(result.data!);
    final session = parsed.startTorrentSession;
    if (session == null) {
      throw Exception('No session data returned from server');
    }
    return {
      'id': session.id,
      'title': session.releaseTitle,
    };
  }

  Future<bool> endSession(String sessionId) async {
    final result = await _client.mutate(
      MutationOptions(
        document: documentNodeMutationEndTorrentSession,
        variables: Variables$Mutation$EndTorrentSession(
          sessionId: sessionId,
        ).toJson(),
      ),
    );

    if (result.hasException) {
      throw result.exception!;
    }

    final parsed = Mutation$EndTorrentSession.fromJson(result.data!);
    return parsed.endTorrentSession ?? false;
  }
}
