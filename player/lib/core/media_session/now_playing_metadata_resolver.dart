import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:graphql_flutter/graphql_flutter.dart';

import '../graphql/graphql_provider.dart';
import 'media_session_state.dart';

/// Runs one GraphQL query and returns its `data`, or null.
typedef NowPlayingFetch = Future<Map<String, dynamic>?> Function(
    String document, Map<String, dynamic> variables);

/// Thrown by a [NowPlayingFetch] when there is currently no way to reach the
/// server (no GraphQL client yet, e.g. playback started during startup or a
/// reconnect) rather than a real, terminal failure. The resolver treats this
/// as unmemoisable so the next [NowPlayingMetadataResolver.resolve] call for
/// the same ids fetches again instead of returning a permanently cached null.
class NowPlayingFetchUnavailable implements Exception {}

const _episodeQuery = r'''
query NowPlayingEpisode($id: ID!) {
  episode(id: $id) {
    seasonNumber
    episodeNumber
    title
    show {
      title
      artwork { posterUrl }
    }
  }
}
''';

const _movieQuery = r'''
query NowPlayingMovie($id: ID!) {
  movie(id: $id) {
    year
    artwork { posterUrl }
  }
}
''';

/// Looks up the poster and second line for whatever is playing, from the ids
/// the player snapshot already carries.
///
/// Memoised per item for the app's lifetime, failures included: an offline
/// download would otherwise re-query on every play/pause.
class NowPlayingMetadataResolver {
  NowPlayingMetadataResolver(this._fetch);

  final NowPlayingFetch _fetch;
  final _cache = <String, Future<NowPlayingMetadata?>>{};

  Future<NowPlayingMetadata?> resolve(
      {String? mediaItemId, String? episodeId}) {
    if (mediaItemId == null && episodeId == null) return Future.value(null);
    final key = '$mediaItemId|$episodeId';
    return _cache.putIfAbsent(key, () => _load(mediaItemId, episodeId, key));
  }

  Future<NowPlayingMetadata?> _load(
      String? mediaItemId, String? episodeId, String key) async {
    try {
      if (episodeId != null) {
        final data = await _fetch(_episodeQuery, {'id': episodeId});
        final episode = data?['episode'];
        return episode is Map<String, dynamic> ? _episode(episode) : null;
      }
      final data = await _fetch(_movieQuery, {'id': mediaItemId});
      final movie = data?['movie'];
      return movie is Map<String, dynamic> ? _movie(movie) : null;
    } on NowPlayingFetchUnavailable {
      // No server connection yet, not a terminal failure: let the next
      // resolve for the same ids try again instead of memoising this null.
      _cache.remove(key);
      return null;
    } catch (e) {
      debugPrint('[MediaSession] metadata lookup failed: $e');
      return null;
    }
  }

  NowPlayingMetadata _episode(Map<String, dynamic> episode) {
    final show = episode['show'] as Map<String, dynamic>?;
    final season = episode['seasonNumber'] as int?;
    final number = episode['episodeNumber'] as int?;
    final parts = <String>[
      if (show?['title'] case final String title) title,
      if (season != null && number != null) 'S${season}E$number',
    ];
    return NowPlayingMetadata(
      title: episode['title'] as String?,
      subtitle: parts.isEmpty ? null : parts.join(' · '),
      posterUrl: _posterOf(show?['artwork']),
    );
  }

  NowPlayingMetadata _movie(Map<String, dynamic> movie) => NowPlayingMetadata(
        subtitle: (movie['year'] as int?)?.toString(),
        posterUrl: _posterOf(movie['artwork']),
      );

  String? _posterOf(Object? artwork) =>
      artwork is Map<String, dynamic> ? artwork['posterUrl'] as String? : null;
}

final nowPlayingMetadataResolverProvider =
    Provider<NowPlayingMetadataResolver>((ref) {
  return NowPlayingMetadataResolver((document, variables) async {
    // Read per call, not captured: the client is rebuilt on reconnect and
    // token refresh.
    final client = ref.read(graphqlClientProvider);
    if (client == null) throw NowPlayingFetchUnavailable();
    final result = await client.query(QueryOptions(
      document: gql(document),
      variables: variables,
      // A detail screen usually just loaded this item.
      fetchPolicy: FetchPolicy.cacheFirst,
    ));
    if (result.hasException) return null;
    return result.data;
  });
});
