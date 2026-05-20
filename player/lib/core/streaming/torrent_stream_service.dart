import 'package:graphql_flutter/graphql_flutter.dart';
import '../../domain/models/torrent_candidate.dart';

class TorrentStreamService {
  final GraphQLClient _client;

  TorrentStreamService(this._client);

  static const String torrentCandidatesQuery = r'''
    query TorrentCandidates($contentType: String!, $id: ID!) {
      torrentCandidates(contentType: $contentType, id: $id) {
        title
        size
        seeders
        leechers
        magnetLink
        indexer
        quality
        healthScore
      }
    }
  ''';

  static const String startTorrentSessionMutation = r'''
    mutation StartTorrentSession($magnetLink: String!, $releaseTitle: String!, $mediaItemId: ID, $episodeId: ID) {
      startTorrentSession(magnetLink: $magnetLink, releaseTitle: $releaseTitle, mediaItemId: $mediaItemId, episodeId: $episodeId) {
        id
        magnetLink
        releaseTitle
      }
    }
  ''';

  static const String endTorrentSessionMutation = r'''
    mutation EndTorrentSession($sessionId: ID!) {
      endTorrentSession(sessionId: $sessionId)
    }
  ''';

  Future<List<TorrentCandidate>> getCandidates(String contentType, String id) async {
    final result = await _client.query(
      QueryOptions(
        document: gql(torrentCandidatesQuery),
        variables: {
          'contentType': contentType,
          'id': id,
        },
        fetchPolicy: FetchPolicy.networkOnly,
      ),
    );

    if (result.hasException) {
      throw result.exception!;
    }

    final List<dynamic> candidatesJson = result.data?['torrentCandidates'] ?? [];
    return candidatesJson.map((json) => TorrentCandidate.fromJson(json)).toList();
  }

  Future<Map<String, String>> startSession({
    required String magnetLink,
    required String releaseTitle,
    String? mediaItemId,
    String? episodeId,
  }) async {
    final result = await _client.mutate(
      MutationOptions(
        document: gql(startTorrentSessionMutation),
        variables: {
          'magnetLink': magnetLink,
          'releaseTitle': releaseTitle,
          'mediaItemId': mediaItemId,
          'episodeId': episodeId,
        },
      ),
    );

    if (result.hasException) {
      throw result.exception!;
    }

    final data = result.data?['startTorrentSession'];
    return {
      'id': data['id'] as String,
      'title': data['releaseTitle'] as String,
    };
  }

  Future<bool> endSession(String sessionId) async {
    final result = await _client.mutate(
      MutationOptions(
        document: gql(endTorrentSessionMutation),
        variables: {
          'sessionId': sessionId,
        },
      ),
    );

    if (result.hasException) {
      throw result.exception!;
    }

    return result.data?['endTorrentSession'] as bool? ?? false;
  }
}
