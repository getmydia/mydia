import '../media_names.dart';

DateTime _date(Object? v) => DateTime.fromMillisecondsSinceEpoch(v as int);

/// A directory the user added as a files library.
class LibraryRoot {
  const LibraryRoot({
    required this.id,
    required this.path,
    required this.kind,
    required this.title,
  });

  final String id;
  final String path;
  final FilesLibraryKind kind;
  final String title;

  Map<String, dynamic> toMap() => {
        'id': id,
        'path': path,
        'kind': kind.name,
        'title': title,
      };

  factory LibraryRoot.fromMap(Map<dynamic, dynamic> m) => LibraryRoot(
        id: m['id'] as String,
        path: m['path'] as String,
        kind: FilesLibraryKind.values.byName(m['kind'] as String),
        title: m['title'] as String,
      );
}

/// One media file found under a root. [path] is relative to the root.
class IndexedFile {
  const IndexedFile({
    required this.key,
    required this.rootId,
    required this.path,
    required this.size,
    required this.modified,
    required this.firstSeen,
    this.parsed,
    this.sidecars = const [],
    this.parsedAs,
  });

  final String key;
  final String rootId;
  final String path;
  final int size;
  final DateTime modified;
  final DateTime firstSeen;
  final ParsedName? parsed;
  final List<String> sidecars;

  /// The root's kind when [parsed] was read: a root whose kind changes has
  /// its files read again, since the kind steers the parser.
  final FilesLibraryKind? parsedAs;

  Map<String, dynamic> toMap() => {
        'key': key,
        'rootId': rootId,
        'path': path,
        'size': size,
        'modified': modified.millisecondsSinceEpoch,
        'firstSeen': firstSeen.millisecondsSinceEpoch,
        'parsed': parsed?.toMap(),
        'sidecars': sidecars,
        'parsedAs': parsedAs?.name,
      };

  factory IndexedFile.fromMap(Map<dynamic, dynamic> m) {
    final parsed = m['parsed'] as Map<dynamic, dynamic>?;
    final parsedAs = m['parsedAs'] as String?;
    return IndexedFile(
      parsedAs: parsedAs == null
          ? null
          : FilesLibraryKind.values.asNameMap()[parsedAs],
      key: m['key'] as String,
      rootId: m['rootId'] as String,
      path: m['path'] as String,
      size: m['size'] as int,
      modified: _date(m['modified']),
      firstSeen: _date(m['firstSeen']),
      parsed: parsed == null ? null : ParsedName.fromMap(parsed),
      sidecars: [for (final s in m['sidecars'] as List) s as String],
    );
  }
}

/// The TMDB answer for one group of files. [tmdbId] is null when unmatched.
class GroupMatch {
  const GroupMatch({
    required this.groupKey,
    required this.isShow,
    required this.matchedAt,
    this.tmdbId,
    this.pinned = false,
  });

  final String groupKey;
  final bool isShow;
  final int? tmdbId;
  final bool pinned;
  final DateTime matchedAt;

  GroupMatch copyWith({
    String? groupKey,
    bool? isShow,
    int? tmdbId,
    bool? pinned,
    DateTime? matchedAt,
  }) =>
      GroupMatch(
        groupKey: groupKey ?? this.groupKey,
        isShow: isShow ?? this.isShow,
        tmdbId: tmdbId ?? this.tmdbId,
        pinned: pinned ?? this.pinned,
        matchedAt: matchedAt ?? this.matchedAt,
      );

  Map<String, dynamic> toMap() => {
        'groupKey': groupKey,
        'isShow': isShow,
        'tmdbId': tmdbId,
        'pinned': pinned,
        'matchedAt': matchedAt.millisecondsSinceEpoch,
      };

  factory GroupMatch.fromMap(Map<dynamic, dynamic> m) => GroupMatch(
        groupKey: m['groupKey'] as String,
        isShow: m['isShow'] as bool,
        tmdbId: m['tmdbId'] as int?,
        pinned: m['pinned'] as bool,
        matchedAt: _date(m['matchedAt']),
      );
}

class MatchedMovie {
  const MatchedMovie({
    required this.tmdbId,
    required this.title,
    this.year,
    this.overview,
    this.posterPath,
    this.backdropPath,
    this.runtimeMinutes,
    this.releaseDate,
  });

  final int tmdbId;
  final String title;
  final int? year;
  final String? overview;
  final String? posterPath;
  final String? backdropPath;
  final int? runtimeMinutes;
  final String? releaseDate;

  Map<String, dynamic> toMap() => {
        'tmdbId': tmdbId,
        'title': title,
        'year': year,
        'overview': overview,
        'posterPath': posterPath,
        'backdropPath': backdropPath,
        'runtimeMinutes': runtimeMinutes,
        'releaseDate': releaseDate,
      };

  factory MatchedMovie.fromMap(Map<dynamic, dynamic> m) => MatchedMovie(
        tmdbId: m['tmdbId'] as int,
        title: m['title'] as String,
        year: m['year'] as int?,
        overview: m['overview'] as String?,
        posterPath: m['posterPath'] as String?,
        backdropPath: m['backdropPath'] as String?,
        runtimeMinutes: m['runtimeMinutes'] as int?,
        releaseDate: m['releaseDate'] as String?,
      );
}

class MatchedEpisode {
  const MatchedEpisode({
    required this.season,
    required this.episode,
    this.title,
    this.overview,
    this.stillPath,
    this.airDate,
    this.runtimeMinutes,
  });

  final int season;
  final int episode;
  final String? title;
  final String? overview;
  final String? stillPath;
  final String? airDate;
  final int? runtimeMinutes;

  Map<String, dynamic> toMap() => {
        'season': season,
        'episode': episode,
        'title': title,
        'overview': overview,
        'stillPath': stillPath,
        'airDate': airDate,
        'runtimeMinutes': runtimeMinutes,
      };

  factory MatchedEpisode.fromMap(Map<dynamic, dynamic> m) => MatchedEpisode(
        season: m['season'] as int,
        episode: m['episode'] as int,
        title: m['title'] as String?,
        overview: m['overview'] as String?,
        stillPath: m['stillPath'] as String?,
        airDate: m['airDate'] as String?,
        runtimeMinutes: m['runtimeMinutes'] as int?,
      );
}

class MatchedShow {
  const MatchedShow({
    required this.tmdbId,
    required this.title,
    this.year,
    this.overview,
    this.posterPath,
    this.backdropPath,
    this.seasons = const {},
  });

  final int tmdbId;
  final String title;
  final int? year;
  final String? overview;
  final String? posterPath;
  final String? backdropPath;
  final Map<int, List<MatchedEpisode>> seasons;

  /// Seasons are stored as a flat episode list (each episode carries its
  /// season), so no map has a non-string key. The season numbers are kept
  /// beside it: a season TMDB lists with no episodes would otherwise vanish
  /// on reload and be fetched again on every scan.
  Map<String, dynamic> toMap() => {
        'tmdbId': tmdbId,
        'title': title,
        'year': year,
        'overview': overview,
        'posterPath': posterPath,
        'backdropPath': backdropPath,
        'seasonNumbers': seasons.keys.toList(),
        'episodes': [
          for (final eps in seasons.values)
            for (final e in eps) e.toMap(),
        ],
      };

  factory MatchedShow.fromMap(Map<dynamic, dynamic> m) {
    final seasons = <int, List<MatchedEpisode>>{
      for (final n in m['seasonNumbers'] as List? ?? const []) n as int: [],
    };
    for (final raw in m['episodes'] as List) {
      final e = MatchedEpisode.fromMap(raw as Map<dynamic, dynamic>);
      seasons.putIfAbsent(e.season, () => []).add(e);
    }
    return MatchedShow(
      tmdbId: m['tmdbId'] as int,
      title: m['title'] as String,
      year: m['year'] as int?,
      overview: m['overview'] as String?,
      posterPath: m['posterPath'] as String?,
      backdropPath: m['backdropPath'] as String?,
      seasons: seasons,
    );
  }
}
