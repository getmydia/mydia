/// A guest Mydia's GraphQL `data` to the neutral source models.
library;

import '../../../domain/sources/item.dart';
import '../source.dart';

String seasonExternalId(String showId, int seasonNumber) =>
    '$showId.s$seasonNumber';

final _seasonId = RegExp(r'^(.+)\.s(\d+)$');

({String showId, int seasonNumber})? parseSeasonExternalId(String externalId) {
  final match = _seasonId.firstMatch(externalId);
  if (match == null) return null;
  return (showId: match.group(1)!, seasonNumber: int.parse(match.group(2)!));
}

Map<String, dynamic> _map(Object? value) =>
    value is Map<String, dynamic> ? value : const {};

List<Map<String, dynamic>> _list(Object? value) => [
      if (value is List)
        for (final v in value)
          if (v is Map<String, dynamic>) v,
    ];

ArtworkRef? _art(Object? url) =>
    url is String && url.isNotEmpty ? ArtworkRef(url) : null;

DateTime? _instant(Object? value) =>
    value is String ? DateTime.tryParse(value)?.toUtc() : null;

int? _minutes(Object? runtime) => runtime is int ? runtime * 60 : null;

UserState _progress(Object? progress, {bool? watched}) {
  final p = _map(progress);
  final position = p['positionSeconds'];
  return UserState(
    watched: watched ?? (p['watched'] as bool? ?? false),
    progressSeconds: position is int && position > 0 ? position : null,
  );
}

String? _firstFileId(Object? files) =>
    _list(files).firstOrNull?['id'] as String?;

ItemRef _ref(SourceId sid, ItemKind kind, String id) =>
    ItemRef(sourceId: sid, kind: kind, externalId: id);

int? _height(Object? resolution) {
  if (resolution is! String) return null;
  return int.tryParse(RegExp(r'\d+').firstMatch(resolution)?.group(0) ?? '');
}

MediaVersion mediaVersion(Map<String, dynamic> file, {int? durationSeconds}) {
  final bps = file['bitrate'];
  return MediaVersion(
    id: file['id'] as String,
    videoCodec: file['codec'] as String?,
    audioCodec: file['audioCodec'] as String?,
    height: _height(file['resolution']),
    bitrateKbps: bps is int && bps > 0 ? (bps / 1000).round() : null,
    durationSeconds: durationSeconds,
    streams: [
      for (final sub in _list(file['subtitles']))
        if (sub['embedded'] != true &&
            sub['deliverable'] != false &&
            sub['url'] is String)
          MediaStreamInfo(
            id: sub['trackId'] as String,
            kind: MediaStreamKind.subtitle,
            codec: 'vtt',
            language: sub['language'] as String?,
            title: sub['title'] as String?,
            externalPath: sub['url'] as String,
          ),
    ],
  );
}

ItemSummary movieSummary(SourceId sid, Map<String, dynamic> m) {
  final artwork = _map(m['artwork']);
  return ItemSummary(
    ref: _ref(sid, ItemKind.movie, m['id'] as String),
    title: m['title'] as String? ?? '',
    year: m['year'] as int?,
    poster: _art(artwork['posterUrl']),
    backdrop: _art(artwork['backdropUrl']),
    durationSeconds: _minutes(m['runtime']),
    userState: _progress(m['progress']),
    overview: m['overview'] as String?,
    defaultVersionId: _firstFileId(m['files']),
    addedAt: _instant(m['addedAt']),
    lastPlayedAt: _instant(_map(m['progress'])['lastWatchedAt']),
  );
}

ItemSummary showSummary(SourceId sid, Map<String, dynamic> s) {
  final artwork = _map(s['artwork']);
  return ItemSummary(
    ref: _ref(sid, ItemKind.show, s['id'] as String),
    title: s['title'] as String? ?? '',
    year: s['year'] as int?,
    poster: _art(artwork['posterUrl']),
    backdrop: _art(artwork['backdropUrl']),
    userState:
        UserState(watched: _map(s['watchStatus'])['watched'] as bool? ?? false),
    childCount: s['seasonCount'] as int?,
    overview: s['overview'] as String?,
    addedAt: _instant(s['addedAt']),
  );
}

ItemSummary seasonSummary(
  SourceId sid,
  String showId,
  Map<String, dynamic> season, {
  ArtworkRef? poster,
}) {
  final number = season['seasonNumber'] as int;
  return ItemSummary(
    ref: _ref(sid, ItemKind.season, seasonExternalId(showId, number)),
    title: number == 0 ? 'Specials' : 'Season $number',
    poster: poster,
    userState: UserState(
        watched: _map(season['watchStatus'])['watched'] as bool? ?? false),
    childCount: season['episodeCount'] as int?,
    index: number,
  );
}

ItemSummary episodeSummary(
  SourceId sid,
  Map<String, dynamic> e, {
  String? showTitle,
}) =>
    ItemSummary(
      ref: _ref(sid, ItemKind.episode, e['id'] as String),
      title: e['title'] as String? ?? '',
      showTitle: showTitle ?? _map(e['show'])['title'] as String?,
      poster: _art(e['thumbnailUrl']),
      durationSeconds: _minutes(e['runtime']),
      userState: _progress(e['progress']),
      index: e['episodeNumber'] as int?,
      parentIndex: e['seasonNumber'] as int?,
      overview: e['overview'] as String?,
      airDate: e['airDate'] as String?,
      defaultVersionId: _firstFileId(e['files']),
      lastPlayedAt: _instant(_map(e['progress'])['lastWatchedAt']),
    );

ItemSummary? continueWatchingSummary(SourceId sid, Map<String, dynamic> c) {
  final kind = switch (c['type']) {
    'MOVIE' => ItemKind.movie,
    'EPISODE' => ItemKind.episode,
    _ => null,
  };
  if (kind == null) return null;
  final artwork = _map(c['artwork']);
  return ItemSummary(
    ref: _ref(sid, kind, c['id'] as String),
    title: c['title'] as String? ?? '',
    showTitle: c['showTitle'] as String?,
    poster: _art(artwork['posterUrl']),
    backdrop: _art(artwork['backdropUrl']),
    durationSeconds: _map(c['progress'])['durationSeconds'] as int?,
    userState: _progress(c['progress']),
    index: c['episodeNumber'] as int?,
    parentIndex: c['seasonNumber'] as int?,
    defaultVersionId: _firstFileId(c['files']),
    lastPlayedAt: _instant(_map(c['progress'])['lastWatchedAt']),
  );
}

ItemSummary? searchResultSummary(SourceId sid, Map<String, dynamic> r) {
  final kind = switch (r['type']) {
    'MOVIE' => ItemKind.movie,
    'TV_SHOW' => ItemKind.show,
    _ => null,
  };
  if (kind == null) return null;
  final artwork = _map(r['artwork']);
  return ItemSummary(
    ref: _ref(sid, kind, r['id'] as String),
    title: r['title'] as String? ?? '',
    year: r['year'] as int?,
    poster: _art(artwork['posterUrl']),
    backdrop: _art(artwork['backdropUrl']),
  );
}

ItemSummary? recentlyAddedSummary(SourceId sid, Map<String, dynamic> r) {
  final base = searchResultSummary(sid, r);
  if (base == null) return null;
  return ItemSummary(
    ref: base.ref,
    title: base.title,
    year: base.year,
    poster: base.poster,
    backdrop: base.backdrop,
    addedAt: _instant(r['addedAt']),
  );
}

List<String> _genres(Object? genres) => [
      if (genres is List)
        for (final g in genres)
          if (g is String) g
    ];

double? _rating(Object? rating) => rating is num ? rating.toDouble() : null;

ItemDetail movieDetail(SourceId sid, Map<String, dynamic> m) {
  final summary = movieSummary(sid, m);
  return ItemDetail(
    summary: summary,
    overview: m['overview'] as String?,
    genres: _genres(m['genres']),
    rating: _rating(m['rating']),
    contentRating: m['contentRating'] as String?,
    isFavorite: m['isFavorite'] as bool? ?? false,
    versions: [
      for (final f in _list(m['files']))
        mediaVersion(f, durationSeconds: summary.durationSeconds),
    ],
  );
}

ItemDetail showDetail(SourceId sid, Map<String, dynamic> s) => ItemDetail(
      summary: showSummary(sid, s),
      overview: s['overview'] as String?,
      genres: _genres(s['genres']),
      rating: _rating(s['rating']),
      contentRating: s['contentRating'] as String?,
      isFavorite: s['isFavorite'] as bool? ?? false,
      trailerUrl: s['trailerUrl'] as String?,
      cast: [
        for (final c in _list(s['cast']))
          Person(
            name: c['name'] as String? ?? '',
            role: c['character'] as String?,
            photo: _art(c['profileUrl']),
          ),
      ],
    );

/// The poster a show's seasons borrow.
ArtworkRef? showPoster(Map<String, dynamic> show) =>
    _art(_map(show['artwork'])['posterUrl']);

ItemDetail seasonDetail(
    SourceId sid, Map<String, dynamic> show, int seasonNumber) {
  final showId = show['id'] as String;
  final season = _list(show['seasons'])
          .where((s) => s['seasonNumber'] == seasonNumber)
          .firstOrNull ??
      {'seasonNumber': seasonNumber};
  return ItemDetail(
    summary: seasonSummary(sid, showId, season, poster: showPoster(show)),
    overview: show['overview'] as String?,
    show: _ref(sid, ItemKind.show, showId),
  );
}

ItemDetail episodeDetail(SourceId sid, Map<String, dynamic> e) {
  final summary = episodeSummary(sid, e);
  final showId = _map(e['show'])['id'] as String?;
  final season = e['seasonNumber'] as int?;
  return ItemDetail(
    summary: summary,
    overview: e['overview'] as String?,
    versions: [
      for (final f in _list(e['files']))
        mediaVersion(f, durationSeconds: summary.durationSeconds),
    ],
    show: showId == null ? null : _ref(sid, ItemKind.show, showId),
    season: showId == null || season == null
        ? null
        : _ref(sid, ItemKind.season, seasonExternalId(showId, season)),
  );
}
