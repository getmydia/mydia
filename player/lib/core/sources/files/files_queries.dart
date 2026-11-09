/// The index of a files library read as movies, shows, seasons, episodes and
/// folders. No I/O: a [FilesCatalog] is built from one read of the index and
/// the progress store, and answers one query.
library;

import '../../../domain/sources/item.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../../playback/local_playback_progress.dart';
import '../../playback/playback_progress_store.dart';
import '../../player/progress_service.dart';
import '../source.dart';
import 'files_ids.dart';
import 'files_listing.dart';
import 'index/file_library_index.dart';
import 'media_names.dart';

export 'files_listing.dart';

/// A position at or past this fraction of the duration counts as watched.
const kFilesWatchedFraction = ProgressService.watchedThreshold;

/// A position under this many seconds is not worth resuming.
const kFilesResumeMinSeconds = 30;

/// Where the backend finds [relative], a path under [root].
String filesBackendPath(LibraryRoot root, String relative) {
  var base = root.path;
  while (base.length > 1 && (base.endsWith('/') || base.endsWith(r'\'))) {
    base = base.substring(0, base.length - 1);
  }
  final sep = base.contains(r'\') && !base.contains('/') ? r'\' : '/';
  return base.endsWith(sep) ? '$base$relative' : '$base$sep$relative';
}

String _nameOf(String path) => path.substring(path.lastIndexOf('/') + 1);

String _stem(String name) {
  final dot = name.lastIndexOf('.');
  return dot > 0 ? name.substring(0, dot) : name;
}

String? _ext(String name) {
  final dot = name.lastIndexOf('.');
  return dot > 0 ? name.substring(dot + 1).toLowerCase() : null;
}

ArtworkRef? _art(String? path) =>
    path == null || path.isEmpty ? null : ArtworkRef(path);

int? _seconds(int? minutes) => minutes == null ? null : minutes * 60;

int _byPath(IndexedFile a, IndexedFile b) => a.path.compareTo(b.path);

/// A movie: one or more groups resolving to the same base.
class FilesMovie {
  FilesMovie(this.base, this.meta, this.parsed);

  final String base;
  final MatchedMovie? meta;
  final ParsedName parsed;
  final files = <IndexedFile>[];

  DateTime get addedAt =>
      files.map((f) => f.firstSeen).reduce((a, b) => a.isBefore(b) ? a : b);
}

/// A show, its files keyed by season, then episode.
class FilesShow {
  FilesShow(this.base, this.meta, this.parsed);

  final String base;
  final MatchedShow? meta;
  final ParsedName parsed;
  final seasons = <int, Map<int, List<IndexedFile>>>{};

  Iterable<IndexedFile> get files =>
      seasons.values.expand((s) => s.values).expand((f) => f);

  /// The newest file: a show is as new as its latest episode.
  DateTime get addedAt =>
      files.map((f) => f.firstSeen).reduce((a, b) => a.isAfter(b) ? a : b);

  List<int> get seasonNumbers => seasons.keys.toList()..sort(compareSeasons);

  /// Every (season, episode) with a file, in viewing order, specials last.
  List<(int, int)> get episodeKeys => [
        for (final s in seasonNumbers)
          for (final e in seasons[s]!.keys.toList()..sort()) (s, e),
      ];

  MatchedEpisode? episodeMeta(int season, int episode) {
    for (final e in meta?.seasons[season] ?? const <MatchedEpisode>[]) {
      if (e.episode == episode) return e;
    }
    return null;
  }
}

/// One query's view of a files library.
class FilesCatalog {
  FilesCatalog._(
      this.sourceId, this._progress, this._l10n, this._watched, this.roots);

  /// Reads [index] once: its files and watched flags are copied per call.
  factory FilesCatalog.read({
    required SourceId sourceId,
    required FileLibraryIndex index,
    required PlaybackProgressStore progress,
    required AppLocalizations l10n,
  }) {
    final catalog = FilesCatalog._(
      sourceId,
      progress,
      l10n,
      index.watched(),
      {for (final r in index.roots()) r.id: r},
    );
    catalog._build(index);
    return catalog;
  }

  final SourceId sourceId;
  final PlaybackProgressStore _progress;
  final AppLocalizations _l10n;
  final Set<String> _watched;
  final Map<String, LibraryRoot> roots;

  final movies = <String, FilesMovie>{};
  final shows = <String, FilesShow>{};

  /// Files no movie or show claims, by file key.
  final unmatched = <String, IndexedFile>{};

  /// The group keys behind each movie or show base, keyed by kind as well:
  /// TMDB numbers movies and shows separately, so movie 1399 and show 1399
  /// share a base and are different titles.
  final groupsOfBase = <(bool isShow, String base), Set<String>>{};

  /// Whether each group is a show.
  final groupIsShow = <String, bool>{};

  /// For an episode held in a multi-episode file (S01E01-E02), the other
  /// episodes of that file. Playing it to the end plays them all.
  ///
  /// Progress is kept per episode, not per file, so two episodes are linked
  /// only when every file of each also holds the other: then whichever was
  /// played, both were. With overlapping files (S01E01-E02 and
  /// S01E02-E03), E02's progress may come from either file, so E02 links to
  /// neither neighbour, and E01 and E03, which share no file, never link.
  final _sameFile = <String, Set<String>>{};

  void _linkSameFileEpisodes(FilesShow show) {
    // For each episode, the other episodes in every one of its files.
    final always = <String, Set<String>>{};
    for (final MapEntry(key: s, value: eps) in show.seasons.entries) {
      for (final MapEntry(key: n, value: files) in eps.entries) {
        Set<String>? common;
        for (final f in files) {
          final p = f.parsed!;
          final first = p.episode!;
          final end = p.episodeEnd ?? first;
          final others = {
            for (var k = first; k <= end; k++)
              if (k != n) episodeId(show.base, s, k),
          };
          common = common == null ? others : common.intersection(others);
        }
        if (common != null && common.isNotEmpty) {
          always[episodeId(show.base, s, n)] = common;
        }
      }
    }
    for (final MapEntry(key: id, value: others) in always.entries) {
      final mutual = {
        for (final o in others)
          if (always[o]?.contains(id) ?? false) o,
      };
      if (mutual.isNotEmpty) _sameFile[id] = mutual;
    }
  }

  /// The episodes sharing a file with [id], which a watched toggle on [id]
  /// carries to as well.
  Set<String> episodesSharingAFile(String id) => _sameFile[id] ?? const {};

  void _build(FileLibraryIndex index) {
    final byGroup = <String, List<IndexedFile>>{};
    for (final f in index.files().values) {
      if (!roots.containsKey(f.rootId)) continue;
      final p = f.parsed;
      if (p == null) {
        unmatched[f.key] = f;
      } else {
        byGroup.putIfAbsent(p.groupKey, () => []).add(f);
      }
    }
    for (final MapEntry(key: key, value: files) in byGroup.entries) {
      files.sort(_byPath);
      final match = index.group(key);
      final first = files.first.parsed!;
      final isShow = match?.isShow ?? first.isEpisode;
      groupIsShow[key] = isShow;
      if (match != null && match.tmdbId == null) {
        for (final f in files) {
          unmatched[f.key] = f;
        }
        continue;
      }
      final tmdbId = match?.tmdbId;
      final base = tmdbId != null ? tmdbBase(tmdbId) : provisionalKey(key);
      groupsOfBase.putIfAbsent((isShow, base), () => {}).add(key);
      if (!isShow) {
        movies
            .putIfAbsent(
                base,
                () => FilesMovie(
                    base, tmdbId == null ? null : index.movie(tmdbId), first))
            .files
            .addAll(files);
        continue;
      }
      final show = shows.putIfAbsent(
          base,
          () => FilesShow(
              base, tmdbId == null ? null : index.show(tmdbId), first));
      for (final f in files) {
        final p = f.parsed!;
        final s = p.season;
        final e = p.episode;
        if (s == null || e == null) {
          unmatched[f.key] = f;
          continue;
        }
        final end = p.episodeEnd ?? e;
        for (var n = e; n <= end; n++) {
          show.seasons.putIfAbsent(s, () => {}).putIfAbsent(n, () => []).add(f);
        }
      }
    }
    shows.removeWhere((_, s) => s.seasons.isEmpty);
    for (final s in shows.values) {
      _linkSameFileEpisodes(s);
    }
    for (final m in movies.values) {
      m.files.sort(_byPath);
    }
    for (final s in shows.values) {
      for (final eps in s.seasons.values) {
        for (final files in eps.values) {
          files.sort(_byPath);
        }
      }
    }
  }

  // Watch state

  ItemRef ref(ItemKind kind, String id) =>
      ItemRef(sourceId: sourceId, kind: kind, externalId: id);

  LocalPlaybackProgress? progressOf(String id) =>
      _progress.get(progressKey(ref(ItemKind.movie, id)));

  bool watched(String id) =>
      _watched.contains(id) ||
      _playedThrough(id) ||
      // Finishing a multi-episode file, played as any one of its episodes,
      // finishes each of them.
      episodesSharingAFile(id).any(_playedThrough);

  bool _playedThrough(String id) {
    final p = progressOf(id);
    return p != null &&
        p.durationSeconds > 0 &&
        p.positionSeconds / p.durationSeconds >= kFilesWatchedFraction;
  }

  /// The position to resume [id] from, or null when it is not under way.
  int? resumeSeconds(String id) {
    if (_watched.contains(id)) return null;
    final p = progressOf(id);
    if (p == null || p.durationSeconds <= 0) return null;
    if (p.positionSeconds < kFilesResumeMinSeconds) return null;
    if (p.positionSeconds / p.durationSeconds >= kFilesWatchedFraction) {
      return null;
    }
    return p.positionSeconds;
  }

  UserState _leafState(String id) =>
      UserState(watched: watched(id), progressSeconds: resumeSeconds(id));

  int unwatchedCount(FilesShow show, {int? season}) {
    var n = 0;
    for (final (s, e) in show.episodeKeys) {
      if (season != null && s != season) continue;
      if (!watched(episodeId(show.base, s, e))) n++;
    }
    return n;
  }

  // Summaries

  ItemSummary movieSummary(FilesMovie m) {
    final id = movieId(m.base);
    final meta = m.meta;
    final title = meta?.title ?? m.parsed.title;
    return ItemSummary(
      ref: ref(ItemKind.movie, id),
      title: title,
      year: meta?.year ?? m.parsed.year,
      poster: _art(meta?.posterPath),
      backdrop: _art(meta?.backdropPath),
      durationSeconds: _seconds(meta?.runtimeMinutes),
      userState: _leafState(id),
      overview: meta?.overview,
      airDate: meta?.releaseDate,
      defaultVersionId: m.files.first.key,
      sortTitle: filesSortTitle(title),
      addedAt: m.addedAt,
      lastPlayedAt: progressOf(id)?.updatedAt,
      externalIds:
          meta == null ? ExternalIds.none : ExternalIds(tmdb: '${meta.tmdbId}'),
    );
  }

  ItemSummary showSummary(FilesShow s) {
    final meta = s.meta;
    final title = meta?.title ?? s.parsed.title;
    final unwatched = unwatchedCount(s);
    return ItemSummary(
      ref: ref(ItemKind.show, showId(s.base)),
      title: title,
      year: meta?.year ?? s.parsed.year,
      poster: _art(meta?.posterPath),
      backdrop: _art(meta?.backdropPath),
      userState: UserState(watched: unwatched == 0, unwatchedCount: unwatched),
      childCount: s.seasons.length,
      overview: meta?.overview,
      sortTitle: filesSortTitle(title),
      addedAt: s.addedAt,
      externalIds:
          meta == null ? ExternalIds.none : ExternalIds(tmdb: '${meta.tmdbId}'),
    );
  }

  ItemSummary seasonSummary(FilesShow s, int season) {
    final show = showSummary(s);
    final eps = s.seasons[season]!;
    final unwatched = unwatchedCount(s, season: season);
    return ItemSummary(
      ref: ref(ItemKind.season, seasonId(s.base, season)),
      title: season == 0
          ? _l10n.filesSpecialsTitle
          : _l10n.filesSeasonTitle(season),
      showTitle: show.title,
      year: show.year,
      poster: show.poster,
      backdrop: show.backdrop,
      userState: UserState(watched: unwatched == 0, unwatchedCount: unwatched),
      childCount: eps.length,
      index: season,
      addedAt: eps.values
          .expand((f) => f)
          .map((f) => f.firstSeen)
          .reduce((a, b) => a.isAfter(b) ? a : b),
      showRef: show.ref,
    );
  }

  ItemSummary episodeSummary(FilesShow s, int season, int episode) {
    final id = episodeId(s.base, season, episode);
    final files = s.seasons[season]![episode]!;
    final meta = s.episodeMeta(season, episode);
    final showTitle = s.meta?.title ?? s.parsed.title;
    return ItemSummary(
      ref: ref(ItemKind.episode, id),
      title: meta?.title ?? _l10n.filesEpisodeTitle(episode),
      subtitle: episodeSubtitle(season, episode),
      showTitle: showTitle,
      poster: _art(meta?.stillPath) ?? _art(s.meta?.posterPath),
      backdrop: _art(s.meta?.backdropPath),
      durationSeconds: _seconds(meta?.runtimeMinutes),
      userState: _leafState(id),
      index: episode,
      parentIndex: season,
      overview: meta?.overview,
      airDate: meta?.airDate,
      defaultVersionId: files.first.key,
      addedAt:
          files.map((f) => f.firstSeen).reduce((a, b) => a.isBefore(b) ? a : b),
      lastPlayedAt: progressOf(id)?.updatedAt,
      showRef: ref(ItemKind.show, showId(s.base)),
    );
  }

  ItemSummary videoSummary(IndexedFile f) {
    final id = unmatchedFileId(f.key);
    final title = _stem(_nameOf(f.path));
    return ItemSummary(
      ref: ref(ItemKind.video, id),
      title: title,
      userState: _leafState(id),
      defaultVersionId: f.key,
      sortTitle: title,
      addedAt: f.firstSeen,
      lastPlayedAt: progressOf(id)?.updatedAt,
    );
  }

  ItemSummary folderSummary(String rootId, String dir) => ItemSummary(
        ref: ref(ItemKind.folder, folderId(rootId, dir)),
        title: dir.isEmpty ? roots[rootId]!.title : _nameOf(dir),
      );

  /// The summary of a movie, episode or loose file by its id, or null.
  ItemSummary? playableSummary(String id) {
    final parsed = parseFilesId(id);
    if (parsed == null) return null;
    if (parsed.fileKey case final key?) {
      final f = unmatched[key];
      return f == null ? null : videoSummary(f);
    }
    final base = parsed.base!;
    final (s, e) = (parsed.season, parsed.episode);
    if (s == null) {
      final m = movies[base];
      return m == null ? null : movieSummary(m);
    }
    if (e == null) return null;
    final show = shows[base];
    if (show?.seasons[s]?[e] == null) return null;
    return episodeSummary(show!, s, e);
  }

  // Details

  List<MediaVersion> versionsOf(List<IndexedFile> files, {int? minutes}) => [
        for (final f in files)
          MediaVersion(
            id: f.key,
            container: _ext(_nameOf(f.path)),
            sizeBytes: f.size,
            durationSeconds: _seconds(minutes),
            streams: _sidecars(f),
          ),
      ];

  List<MediaStreamInfo> _sidecars(IndexedFile f) {
    final root = roots[f.rootId];
    if (root == null) return const [];
    return sidecarStreams(root, f);
  }

  static List<MediaStreamInfo> sidecarStreams(
    LibraryRoot root,
    IndexedFile f,
  ) {
    final stem = _stem(_nameOf(f.path));
    return [
      for (final (i, path) in f.sidecars.indexed)
        _sidecarStatic(i, root, path, stem),
    ];
  }

  static MediaStreamInfo _sidecarStatic(
      int i, LibraryRoot root, String path, String stem) {
    final name = _nameOf(path);
    // `Movie.en.forced.srt`: the parts between the stem and the extension.
    final middle = _stem(name).length > stem.length
        ? _stem(name).substring(stem.length + 1).split('.')
        : const <String>[];
    final language = middle
        .where((p) => RegExp(r'^[A-Za-z]{2,3}$').hasMatch(p))
        .firstOrNull
        ?.toLowerCase();
    return MediaStreamInfo(
      id: 'sidecar-$i',
      kind: MediaStreamKind.subtitle,
      codec: _ext(name),
      language: language,
      title: name,
      externalPath: filesBackendPath(root, path),
    );
  }

  static String mimeOf(String path) {
    final ext = _ext(_nameOf(path));
    return switch (ext) {
      'mkv' => 'video/x-matroska',
      'mp4' || 'm4v' => 'video/mp4',
      'mov' => 'video/quicktime',
      'mpg' || 'mpeg' => 'video/mpeg',
      'avi' => 'video/x-msvideo',
      'ts' || 'mpegts' => 'video/mp2t',
      'webm' => 'video/webm',
      _ => 'video/$ext',
    };
  }

  ItemDetail? detail(ItemRef r) {
    final id = r.externalId;
    switch (r.kind) {
      case ItemKind.folder:
        final folder = parseFolderId(id);
        if (folder == null || !roots.containsKey(folder.rootId)) return null;
        return ItemDetail(summary: folderSummary(folder.rootId, folder.dir));
      case ItemKind.video:
        final key = parseFilesId(id)?.fileKey;
        final f = key == null ? null : unmatched[key];
        if (f == null) return null;
        return ItemDetail(summary: videoSummary(f), versions: versionsOf([f]));
      case ItemKind.movie:
        final m = movies[id];
        if (m == null) return null;
        return ItemDetail(
          summary: movieSummary(m),
          overview: m.meta?.overview,
          versions: versionsOf(m.files, minutes: m.meta?.runtimeMinutes),
        );
      case ItemKind.show:
        final s = shows[id];
        if (s == null) return null;
        return ItemDetail(summary: showSummary(s), overview: s.meta?.overview);
      case ItemKind.season:
        final p = parseFilesId(id);
        final s = shows[p?.base];
        final n = p?.season;
        if (s == null || n == null || s.seasons[n] == null) return null;
        return ItemDetail(
          summary: seasonSummary(s, n),
          show: ref(ItemKind.show, showId(s.base)),
          showPoster: _art(s.meta?.posterPath),
          showBackdrop: _art(s.meta?.backdropPath),
        );
      case ItemKind.episode:
        final p = parseFilesId(id);
        final s = shows[p?.base];
        final (n, e) = (p?.season, p?.episode);
        if (s == null || n == null || e == null) return null;
        final files = s.seasons[n]?[e];
        if (files == null) return null;
        final summary = episodeSummary(s, n, e);
        return ItemDetail(
          summary: summary,
          overview: summary.overview,
          versions:
              versionsOf(files, minutes: s.episodeMeta(n, e)?.runtimeMinutes),
          show: ref(ItemKind.show, showId(s.base)),
          season: ref(ItemKind.season, seasonId(s.base, n)),
          showPoster: _art(s.meta?.posterPath),
          showBackdrop: _art(s.meta?.backdropPath),
        );
    }
  }

  // Listings

  /// Null when [parent] is not here.
  List<ItemSummary>? children(ItemRef parent) {
    final id = parent.externalId;
    switch (parent.kind) {
      case ItemKind.show:
        final s = shows[id];
        if (s == null) return null;
        return [for (final n in s.seasonNumbers) seasonSummary(s, n)];
      case ItemKind.season:
        final p = parseFilesId(id);
        final s = shows[p?.base];
        final n = p?.season;
        final eps = n == null ? null : s?.seasons[n];
        if (s == null || n == null || eps == null) return null;
        return [
          for (final e in eps.keys.toList()..sort()) episodeSummary(s, n, e),
        ];
      case ItemKind.folder:
        final folder = parseFolderId(id);
        if (folder == null || !roots.containsKey(folder.rootId)) return null;
        return _folderChildren(folder.rootId, folder.dir);
      case ItemKind.movie || ItemKind.episode || ItemKind.video:
        return const [];
    }
  }

  List<ItemSummary> _folderChildren(String rootId, String dir) {
    final prefix = dir.isEmpty ? '' : '$dir/';
    final subdirs = <String>{};
    final files = <IndexedFile>[];
    for (final f in unmatched.values) {
      if (f.rootId != rootId || !f.path.startsWith(prefix)) continue;
      final rest = f.path.substring(prefix.length);
      final slash = rest.indexOf('/');
      if (slash < 0) {
        files.add(f);
      } else {
        subdirs.add(rest.substring(0, slash));
      }
    }
    int byName(String a, String b) =>
        a.toLowerCase().compareTo(b.toLowerCase());
    return [
      for (final d in subdirs.toList()..sort(byName))
        folderSummary(rootId, '$prefix$d'),
      for (final f
          in files..sort((a, b) => byName(_nameOf(a.path), _nameOf(b.path))))
        videoSummary(f),
    ];
  }

  /// Movies and shows with a file under [rootId].
  List<ItemSummary> itemsUnder(String rootId) => [
        for (final m in movies.values)
          if (m.files.any((f) => f.rootId == rootId)) movieSummary(m),
        for (final s in shows.values)
          if (s.files.any((f) => f.rootId == rootId)) showSummary(s),
      ];

  /// Every movie and show.
  List<ItemSummary> allTitles() => [
        for (final m in movies.values) movieSummary(m),
        for (final s in shows.values) showSummary(s),
      ];

  /// Roots holding a file no movie or show claims.
  Set<String> get rootsWithUnmatched =>
      {for (final f in unmatched.values) f.rootId};

  /// The episode to play next in [s]: the first unwatched one after the last
  /// watched, specials left out; the first episode when none is watched.
  ItemSummary? nextUp(FilesShow s) {
    final keys = [
      for (final k in s.episodeKeys)
        if (k.$1 != 0) k,
    ];
    var last = -1;
    for (var i = 0; i < keys.length; i++) {
      if (watched(episodeId(s.base, keys[i].$1, keys[i].$2))) last = i;
    }
    for (var i = last + 1; i < keys.length; i++) {
      final (n, e) = keys[i];
      if (!watched(episodeId(s.base, n, e))) return episodeSummary(s, n, e);
    }
    return null;
  }
}
