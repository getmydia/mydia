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

  Future<Map<String, dynamic>> startSession({
    required String magnetLink,
    required String releaseTitle,
    String? mediaItemId,
    String? episodeId,
    int? tmdbId,
    int? tvdbId,
  }) async {
    final result = await _client.mutate(
      MutationOptions(
        document: documentNodeMutationStartTorrentSession,
        variables: Variables$Mutation$StartTorrentSession(
          magnetLink: magnetLink,
          releaseTitle: releaseTitle,
          mediaItemId: mediaItemId,
          episodeId: episodeId,
          tmdbId: tmdbId,
          tvdbId: tvdbId,
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
    // fileId is async on the server (populated after :metadata_ready), so it
    // may be null on the first response. Return it as a nullable int rather
    // than forcing toString() which would mask the null.
    return {
      'id': session.id,
      'title': session.releaseTitle,
      'fileId': session.fileId,
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
