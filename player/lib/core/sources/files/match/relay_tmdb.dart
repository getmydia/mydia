import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../../relay/relay_api_client.dart';
import '../index/index_records.dart';
import '../media_names.dart';

/// The relay could not answer: network error, timeout, 429, 5xx, or a
/// response that cannot be used. The group stays provisional and is retried.
class RelayUnavailable implements Exception {
  RelayUnavailable([this.reason = '']);
  final String reason;

  @override
  String toString() => 'RelayUnavailable($reason)';
}

/// TMDB through the metadata relay, which passes TMDB JSON through unchanged
/// and needs no API key.
class RelayTmdb {
  RelayTmdb({http.Client? client, String baseUrl = metadataRelayBaseUrl})
      : _client = client ?? http.Client(),
        _base = baseUrl.endsWith('/')
            ? baseUrl.substring(0, baseUrl.length - 1)
            : baseUrl;

  static const _timeout = Duration(seconds: 20);

  final http.Client _client;
  final String _base;

  Future<List<TmdbCandidate>> searchMovies(String query, {int? year}) async {
    final json = await _get('/tmdb/movies/search', {
      'query': query,
      if (year != null) 'year': '$year',
    });
    return _candidates(json, 'title', 'original_title', 'release_date');
  }

  Future<List<TmdbCandidate>> searchShows(String query, {int? year}) async {
    final json = await _get('/tmdb/tv/search', {
      'query': query,
      if (year != null) 'first_air_date_year': '$year',
    });
    return _candidates(json, 'name', 'original_name', 'first_air_date');
  }

  Future<MatchedMovie> movie(int id) async {
    final j = await _get('/tmdb/movies/$id', const {});
    return _guard(() {
      final date = j['release_date'] as String?;
      return MatchedMovie(
        tmdbId: id,
        title: j['title'] as String,
        year: _year(date),
        overview: _text(j['overview']),
        posterPath: j['poster_path'] as String?,
        backdropPath: j['backdrop_path'] as String?,
        runtimeMinutes: _positive(j['runtime']),
        releaseDate: _text(date),
      );
    });
  }

  Future<MatchedShow> show(int id, {required Iterable<int> seasons}) async {
    final j = await _get('/tmdb/tv/shows/$id', const {});
    final runtimes = j['episode_run_time'];
    final showRuntime = runtimes is List && runtimes.isNotEmpty
        ? _positive(runtimes.first)
        : null;
    final bySeason = <int, List<MatchedEpisode>>{};
    for (final n in seasons.toSet()) {
      // A season TMDB lacks (specials, a wrong number) is empty, not a
      // failure: its files still belong to the show.
      final s = await _getSeason('/tmdb/tv/shows/$id/$n');
      bySeason[n] = s == null
          ? const []
          : _guard(() => [
                for (final raw in (s['episodes'] as List? ?? const []))
                  _episode(raw as Map<String, dynamic>, n, showRuntime),
              ]);
    }
    return _guard(() => MatchedShow(
          tmdbId: id,
          title: j['name'] as String,
          year: _year(j['first_air_date'] as String?),
          overview: _text(j['overview']),
          posterPath: j['poster_path'] as String?,
          backdropPath: j['backdrop_path'] as String?,
          seasons: bySeason,
        ));
  }

  MatchedEpisode _episode(Map<String, dynamic> e, int season, int? fallback) =>
      MatchedEpisode(
        season: season,
        episode: e['episode_number'] as int,
        title: _text(e['name']),
        overview: _text(e['overview']),
        stillPath: e['still_path'] as String?,
        airDate: _text(e['air_date']),
        runtimeMinutes: _positive(e['runtime']) ?? fallback,
      );

  List<TmdbCandidate> _candidates(
    Map<String, dynamic> json,
    String titleKey,
    String originalKey,
    String dateKey,
  ) =>
      _guard(() => [
            for (final raw in (json['results'] as List? ?? const []))
              TmdbCandidate(
                id: (raw as Map<String, dynamic>)['id'] as int,
                title: (raw[titleKey] as String?) ?? '',
                originalTitle: raw[originalKey] as String?,
                year: _year(raw[dateKey] as String?),
              ),
          ]);

  Future<Map<String, dynamic>> _get(
    String path,
    Map<String, String> query,
  ) async =>
      (await _getOrNull(path, query, missingOk: false))!;

  Future<Map<String, dynamic>?> _getSeason(String path) =>
      _getOrNull(path, const {}, missingOk: true);

  Future<Map<String, dynamic>?> _getOrNull(
    String path,
    Map<String, String> query, {
    required bool missingOk,
  }) async {
    final uri = Uri.parse('$_base$path')
        .replace(queryParameters: query.isEmpty ? null : query);
    final http.Response res;
    try {
      res = await _client.get(uri).timeout(_timeout);
    } on Object catch (e) {
      throw RelayUnavailable('$path: $e');
    }
    if (missingOk && res.statusCode == 404) return null;
    if (res.statusCode != 200) {
      throw RelayUnavailable('$path: HTTP ${res.statusCode}');
    }
    try {
      return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    } on Object catch (e) {
      throw RelayUnavailable('$path: unreadable body: $e');
    }
  }

  T _guard<T>(T Function() build) {
    try {
      return build();
    } on Object catch (e) {
      throw RelayUnavailable('unexpected payload: $e');
    }
  }

  static int? _year(String? date) {
    if (date == null || date.length < 4) return null;
    return int.tryParse(date.substring(0, 4));
  }

  static String? _text(Object? v) => v is String && v.isNotEmpty ? v : null;

  static int? _positive(Object? v) => v is int && v > 0 ? v : null;
}
