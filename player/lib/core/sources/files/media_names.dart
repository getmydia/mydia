import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show PlatformInt64Util;

import '../../../native/media_names.dart' as native;

/// What a files-library directory holds, which steers how names are parsed.
enum FilesLibraryKind { movies, series, mixed }

/// One media path read as a title, year and (for episodes) season/episode.
class ParsedName {
  const ParsedName({
    required this.path,
    required this.isEpisode,
    required this.title,
    required this.groupKey,
    this.year,
    this.season,
    this.episode,
    this.episodeEnd,
  });

  final String path;
  final bool isEpisode;
  final String title;
  final int? year;
  final int? season;
  final int? episode;
  final int? episodeEnd;

  /// Files describing the same movie or show share a key.
  final String groupKey;

  Map<String, dynamic> toMap() => {
        'path': path,
        'isEpisode': isEpisode,
        'title': title,
        'groupKey': groupKey,
        'year': year,
        'season': season,
        'episode': episode,
        'episodeEnd': episodeEnd,
      };

  factory ParsedName.fromMap(Map<dynamic, dynamic> m) => ParsedName(
        path: m['path'] as String,
        isEpisode: m['isEpisode'] as bool,
        title: m['title'] as String,
        groupKey: m['groupKey'] as String,
        year: m['year'] as int?,
        season: m['season'] as int?,
        episode: m['episode'] as int?,
        episodeEnd: m['episodeEnd'] as int?,
      );
}

class TmdbCandidate {
  const TmdbCandidate({
    required this.id,
    required this.title,
    this.originalTitle,
    this.year,
  });

  final int id;
  final String title;
  final String? originalTitle;
  final int? year;
}

class TmdbMatch {
  const TmdbMatch({required this.id, required this.confidence});

  final int id;
  final double confidence;
}

/// Filename parsing and TMDB match scoring. The real implementation is Rust,
/// shared with the server; tests use a fake.
abstract interface class MediaNames {
  List<ParsedName> parseBatch(
    String root,
    List<String> paths,
    FilesLibraryKind kind,
  );

  TmdbMatch? score(
    String title,
    int? year, {
    required bool isShow,
    required List<TmdbCandidate> candidates,
  });
}

class RustMediaNames implements MediaNames {
  @override
  List<ParsedName> parseBatch(
    String root,
    List<String> paths,
    FilesLibraryKind kind,
  ) {
    final parsed = native.parseBatch(
      root: root,
      paths: paths,
      kind: switch (kind) {
        FilesLibraryKind.movies => native.FfiKind.movies,
        FilesLibraryKind.series => native.FfiKind.series,
        FilesLibraryKind.mixed => native.FfiKind.mixed,
      },
    );
    return [
      for (final p in parsed)
        ParsedName(
          path: p.path,
          isEpisode: p.isEpisode,
          title: p.title,
          year: p.year,
          season: p.season,
          episode: p.episode,
          episodeEnd: p.episodeEnd,
          groupKey: p.groupKey,
        ),
    ];
  }

  @override
  TmdbMatch? score(
    String title,
    int? year, {
    required bool isShow,
    required List<TmdbCandidate> candidates,
  }) {
    final match = native.scoreCandidates(
      title: title,
      year: year,
      isShow: isShow,
      candidates: [
        for (final c in candidates)
          native.FfiCandidate(
            id: PlatformInt64Util.from(c.id),
            title: c.title,
            originalTitle: c.originalTitle,
            year: c.year,
          ),
      ],
    );
    if (match == null) return null;
    return TmdbMatch(id: match.id.toInt(), confidence: match.confidence);
  }
}

final mediaNamesProvider = Provider<MediaNames>((ref) => RustMediaNames());
