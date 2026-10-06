import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gql/ast.dart' show DocumentNode;

import '../../domain/sources/source_error.dart';
import '../../graphql/queries/now_playing.graphql.dart';
import '../sources/mydia/bound_mydia.dart';
import 'media_session_state.dart';

/// Runs one GraphQL query and returns its `data`, or null.
typedef NowPlayingFetch = Future<Map<String, dynamic>?> Function(
    DocumentNode document, Map<String, dynamic> variables);

/// Thrown by a [NowPlayingFetch] when there is currently no way to reach the
/// server (no GraphQL client yet, e.g. playback started during startup or a
/// reconnect) rather than a real, terminal failure. The resolver treats this
/// as unmemoisable so the next [NowPlayingMetadataResolver.resolve] call for
/// the same ids fetches again instead of returning a permanently cached null.
class NowPlayingFetchUnavailable implements Exception {}

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
        final data = await _fetch(
          documentNodeQueryNowPlayingEpisode,
          Variables$Query$NowPlayingEpisode(id: episodeId).toJson(),
        );
        final episode = data?['episode'];
        return episode is Map<String, dynamic> ? _episode(episode) : null;
      }
      final data = await _fetch(
        documentNodeQueryNowPlayingMovie,
        Variables$Query$NowPlayingMovie(id: mediaItemId!).toJson(),
      );
      final movie = data?['movie'];
      return movie is Map<String, dynamic> ? _movie(movie) : null;
    } on NowPlayingFetchUnavailable {
      // No server connection yet, not a terminal failure: let the next
      // resolve for the same ids try again instead of memoising this null.
      // Only drops the memo entry; this call's own result is returned below.
      unawaited(_cache.remove(key));
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
    final client = ref.read(boundMydiaClientProvider);
    if (client == null) throw NowPlayingFetchUnavailable();
    try {
      return await client.request(document, variables);
    } on SourceException {
      return null;
    }
  });
});
