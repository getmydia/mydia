import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../../../../domain/sources/item.dart';
import '../../../playback/local_playback_progress.dart';
import '../../../playback/playback_progress_store.dart';
import '../../source.dart';
import '../files_ids.dart';
import '../index/file_library_index.dart';
import '../media_names.dart';
import 'relay_tmdb.dart';

export 'relay_tmdb.dart';

/// Matches the groups of a files library against TMDB through the relay.
class FileMatcher {
  FileMatcher({
    required RelayTmdb tmdb,
    required MediaNames names,
    required FileLibraryIndex index,
    required PlaybackProgressStore progress,
    required SourceId sourceId,
    Future<void> Function()? onGroupLanded,
    int concurrency = 4,
    DateTime Function()? now,
  })  : _tmdb = tmdb,
        _names = names,
        _index = index,
        _progress = progress,
        _sourceId = sourceId,
        _onGroupLanded = onGroupLanded,
        _slots = _Semaphore(concurrency),
        _now = now ?? DateTime.now;

  final RelayTmdb _tmdb;
  final MediaNames _names;
  final FileLibraryIndex _index;
  final PlaybackProgressStore _progress;
  final SourceId _sourceId;
  final Future<void> Function()? _onGroupLanded;
  final _Semaphore _slots;
  final DateTime Function() _now;

  /// Matches every group with no [GroupMatch], or whose files are newer than
  /// it. A group the relay cannot answer for stays provisional (no
  /// [GroupMatch]); the others carry on.
  Future<void> matchPending() async {
    final groups = _groups();
    final pending = [
      for (final g in groups.values)
        if (_needsWork(g)) g,
    ];
    final clock = Stopwatch()..start();
    await Future.wait([for (final g in pending) _matchOne(g)]);
    if (pending.isEmpty) return;
    final matched =
        pending.where((g) => _index.group(g.key)?.tmdbId != null).length;
    final provisional =
        pending.where((g) => _index.group(g.key) == null).length;
    debugPrint('[FileMatcher] matched ${pending.length} of ${groups.length} '
        'groups in ${clock.elapsed.inSeconds}s: $matched found, '
        '${pending.length - matched - provisional} with no match, '
        '$provisional left provisional');
  }

  /// Fixes a group to [tmdbId], or to "no match" when null. A pinned group is
  /// never searched again. Throws [RelayUnavailable] when details are needed
  /// and the relay is down; nothing is written then.
  Future<void> pin(
    String groupKey, {
    required bool isShow,
    int? tmdbId,
  }) =>
      _serialized(
          groupKey, () => _pin(groupKey, isShow: isShow, tmdbId: tmdbId));

  Future<void> _pin(
    String groupKey, {
    required bool isShow,
    int? tmdbId,
  }) async {
    final files = _filesOf(groupKey, isShow);
    if (tmdbId == null) {
      final previous = _index.group(groupKey);
      await _migrateToFiles(_Group(groupKey, isShow, files), previous?.tmdbId);
      await _index.putGroup(GroupMatch(
        groupKey: groupKey,
        isShow: isShow,
        matchedAt: _now(),
        pinned: true,
      ));
    } else {
      final group = _Group(groupKey, isShow, files);
      await _fetchAndStore(group, tmdbId);
      // Read after the fetch: what the group resolves to now is where its
      // state is.
      final previous = _index.group(groupKey);
      await _migrateProgress(group, tmdbId, previous?.tmdbId);
      await _index.putGroup(GroupMatch(
        groupKey: groupKey,
        isShow: isShow,
        tmdbId: tmdbId,
        pinned: true,
        matchedAt: _now(),
      ));
    }
    await _onGroupLanded?.call();
  }

  // Grouping

  Map<String, _Group> _groups() {
    final byKey = <String, List<IndexedFile>>{};
    for (final f in _index.files().values) {
      final p = f.parsed;
      if (p == null) continue;
      byKey.putIfAbsent(p.groupKey, () => []).add(f);
    }
    return {
      for (final e in byKey.entries)
        e.key: _Group(
          e.key,
          e.value.first.parsed!.isEpisode,
          e.value..sort((a, b) => a.path.compareTo(b.path)),
        ),
    };
  }

  List<IndexedFile> _filesOf(String groupKey, bool isShow) =>
      (_groups()[groupKey]?.files ?? const <IndexedFile>[]);

  bool _needsWork(_Group g) {
    final m = _index.group(g.key);
    if (m == null) return true;
    if (m.pinned) {
      return m.tmdbId != null &&
          g.isShow &&
          _missingSeasons(g, m.tmdbId!).isNotEmpty;
    }
    return g.files.any(
      (f) =>
          f.firstSeen.isAfter(m.matchedAt) || f.modified.isAfter(m.matchedAt),
    );
  }

  Set<int> _seasons(_Group g) => {
        for (final f in g.files)
          if (f.parsed!.season != null) f.parsed!.season!,
      };

  Set<int> _missingSeasons(_Group g, int tmdbId) {
    final have = _index.show(tmdbId)?.seasons.keys.toSet() ?? const <int>{};
    return _seasons(g).difference(have);
  }

  // Matching

  /// The last operation queued on each group key.
  final _locks = <String, Future<void>>{};

  /// Runs [body] after every earlier [pin] or automatic match of [key] has
  /// ended, so the two never interleave on one group: a pin either lands
  /// before the search (and the search sees it) or after it (and moves the
  /// state from what the search chose).
  Future<T> _serialized<T>(String key, Future<T> Function() body) {
    final previous = _locks[key] ?? Future<void>.value();
    final done = previous.then((_) => body());
    final settled = done.then<void>((_) {}, onError: (Object _) {});
    _locks[key] = settled;
    unawaited(settled.then((_) {
      if (identical(_locks[key], settled)) _locks.remove(key);
    }));
    return done;
  }

  Future<void> _matchOne(_Group g) => _serialized(g.key, () => _matchOneNow(g));

  Future<void> _matchOneNow(_Group g) async {
    try {
      final existing = _index.group(g.key);
      if (existing != null && existing.pinned) {
        // Pinned, possibly by a pin queued ahead of this match.
        final pinnedTo = existing.tmdbId;
        if (pinnedTo == null) return;
        final missing = _missingSeasons(g, pinnedTo);
        if (!g.isShow || missing.isEmpty) return;
        await _fetchAndStore(g, pinnedTo, onlySeasons: missing);
        await _onGroupLanded?.call();
        return;
      }

      final first = g.files.first.parsed!;
      // A show's search leaves the year out: TMDB's first_air_date_year
      // drops every show that premiered in another year, while the year in
      // a file name is often a later season's, so the scorer weighs it
      // instead.
      final candidates = g.isShow
          ? await _limited(() => _tmdb.searchShows(first.title))
          : await _limited(
              () => _tmdb.searchMovies(first.title, year: first.year));
      final hit = _names.score(
        first.title,
        first.year,
        isShow: g.isShow,
        candidates: candidates,
      );
      // A Fix match pin can land at any await from here on. The migrations
      // stop before their next move once it has, and the group is written
      // only if it is still unpinned, checked and written in one step.
      bool pinned() => _pinnedMeanwhile(g.key);
      if (pinned()) return;
      final bool wrote;
      if (hit == null) {
        // State kept under the provisional id (or a previous match) while
        // the group waited goes to the files, which is where Folders reads.
        await _migrateToFiles(g, existing?.tmdbId, stop: pinned);
        wrote = await _index.putGroupUnlessPinned(GroupMatch(
          groupKey: g.key,
          isShow: g.isShow,
          matchedAt: _now(),
        ));
      } else {
        await _fetchAndStore(g, hit.id);
        if (pinned()) return;
        await _migrateProgress(g, hit.id, existing?.tmdbId, stop: pinned);
        wrote = await _index.putGroupUnlessPinned(GroupMatch(
          groupKey: g.key,
          isShow: g.isShow,
          tmdbId: hit.id,
          matchedAt: _now(),
        ));
      }
      if (wrote) await _onGroupLanded?.call();
    } on RelayUnavailable catch (e) {
      debugPrint('[FileMatcher] ${g.key} stays provisional: $e');
    }
  }

  /// Whether Fix match pinned [key] while an automatic search for it was
  /// under way: the viewer's choice stands, and the search result is
  /// dropped.
  bool _pinnedMeanwhile(String key) => _index.group(key)?.pinned ?? false;

  /// Whether a group other than [g] still resolves to [tmdbId]: the state
  /// under that id is then theirs too, and is copied rather than moved.
  bool _sharedWithOtherGroup(_Group g, int tmdbId) {
    for (final key in _groups().keys) {
      if (key == g.key) continue;
      final m = _index.group(key);
      if (m != null && m.tmdbId == tmdbId && m.isShow == g.isShow) return true;
    }
    return false;
  }

  Future<void> _fetchAndStore(
    _Group g,
    int tmdbId, {
    Set<int>? onlySeasons,
  }) async {
    if (!g.isShow) {
      await _index.putMovie(await _limited(() => _tmdb.movie(tmdbId)));
      return;
    }
    final wanted = onlySeasons ?? _seasons(g);
    final fetched = await _limited(() => _tmdb.show(tmdbId, seasons: wanted));
    final old = _index.show(tmdbId);
    await _index.putShow(MatchedShow(
      tmdbId: fetched.tmdbId,
      title: fetched.title,
      year: fetched.year,
      overview: fetched.overview,
      posterPath: fetched.posterPath,
      backdropPath: fetched.backdropPath,
      seasons: {...?old?.seasons, ...fetched.seasons},
    ));
  }

  // Progress migration

  /// The items a group's files make up that carry state, with the file ids
  /// that stand in for each when the group is unmatched.
  List<_Item> _items(_Group g) {
    if (!g.isShow) {
      return [
        _Item(ItemKind.movie, movieId, [for (final f in g.files) f.key]),
      ];
    }
    final eps = <(int, int), List<String>>{};
    for (final f in g.files) {
      final p = f.parsed!;
      final s = p.season;
      final e = p.episode;
      if (s == null || e == null) continue;
      for (var n = e; n <= (p.episodeEnd ?? e); n++) {
        eps.putIfAbsent((s, n), () => []).add(f.key);
      }
    }
    // A show and its seasons hold no progress or watched flag of their own,
    // and a show's id is its bare base, which is also the id of the movie
    // with the same TMDB number: moving it would carry that movie's state.
    return [
      for (final e in eps.entries)
        _Item(
            ItemKind.episode, (b) => episodeId(b, e.key.$1, e.key.$2), e.value),
    ];
  }

  /// Moves progress and watched flags from the ids this group had before
  /// (provisional, a previous TMDB id when it changed, and each file's
  /// unmatched id) to [newTmdbId]. Ends early, before any further move,
  /// once [stop] says so.
  Future<void> _migrateProgress(_Group g, int newTmdbId, int? previousTmdb,
      {bool Function()? stop}) async {
    bool stopped() => stop?.call() ?? false;
    final newBase = tmdbBase(newTmdbId);
    final sharedBase = previousTmdb != null &&
            previousTmdb != newTmdbId &&
            _sharedWithOtherGroup(g, previousTmdb)
        ? tmdbBase(previousTmdb)
        : null;
    final oldBases = <String>{
      provisionalKey(g.key),
      if (previousTmdb != null && previousTmdb != newTmdbId)
        tmdbBase(previousTmdb),
    };
    final watched = _index.watched();
    // A file holding several episodes (S01E01-E02) stands in for each of
    // them, so its state goes to all of them in one move: one move per
    // episode would delete it after the first.
    final fromFiles = <String, List<String>>{};
    final type = g.isShow ? 'episode' : 'movie';
    for (final item in _items(g)) {
      final target = item.id(newBase);
      for (final oldBase in oldBases) {
        if (stopped()) return;
        await _move(item.kind, item.id(oldBase), [target], watched,
            mediaType: type, keepSource: oldBase == sharedBase);
      }
      for (final key in item.fileIds) {
        fromFiles.putIfAbsent(key, () => []).add(target);
      }
    }
    for (final MapEntry(key: key, value: targets) in fromFiles.entries) {
      if (stopped()) return;
      await _move(ItemKind.video, unmatchedFileId(key), targets, watched,
          mediaType: type);
    }
  }

  /// The reverse: a matched group is unmatched, so each movie or episode's
  /// progress is copied to every one of its files' unmatched ids.
  Future<void> _migrateToFiles(_Group g, int? previousTmdb,
      {bool Function()? stop}) async {
    final sharedBase =
        previousTmdb != null && _sharedWithOtherGroup(g, previousTmdb)
            ? tmdbBase(previousTmdb)
            : null;
    final oldBases = <String>{
      provisionalKey(g.key),
      if (previousTmdb != null) tmdbBase(previousTmdb),
    };
    final watched = _index.watched();
    for (final item in _items(g)) {
      if (item.fileIds.isEmpty) continue;
      final targets = [for (final k in item.fileIds) unmatchedFileId(k)];
      for (final oldBase in oldBases) {
        if (stop?.call() ?? false) return;
        await _move(item.kind, item.id(oldBase), targets, watched,
            keepSource: oldBase == sharedBase);
      }
    }
  }

  /// Moves one item's record and watched flag from [oldId] to every id in
  /// [newIds]. Where a record already exists at a target, the newer
  /// `updatedAt` wins. With [keepSource] the state is copied: another group
  /// still shows [oldId].
  Future<void> _move(
    ItemKind kind,
    String oldId,
    List<String> newIds,
    Set<String> watched, {
    String? mediaType,
    bool keepSource = false,
  }) async {
    ItemRef ref(ItemKind k, String id) =>
        ItemRef(sourceId: _sourceId, kind: k, externalId: id);
    final oldKey = progressKey(ref(kind, oldId));
    final old = _progress.get(oldKey);
    if (old != null) {
      for (final newId in newIds) {
        final existing = _progress.get(progressKey(ref(kind, newId)));
        if (existing != null && !old.updatedAt.isAfter(existing.updatedAt)) {
          continue;
        }
        await _progress.save(LocalPlaybackProgress(
          sourceId: old.sourceId,
          mediaId: newId,
          mediaType: mediaType ?? old.mediaType,
          positionSeconds: old.positionSeconds,
          durationSeconds: old.durationSeconds,
          updatedAt: old.updatedAt,
          syncedAt: old.syncedAt,
        ));
      }
      if (!keepSource) await _progress.delete(oldKey);
    }
    if (watched.contains(oldId)) {
      for (final newId in newIds) {
        await _index.setWatched(newId, true);
      }
      if (!keepSource) await _index.setWatched(oldId, false);
    }
  }

  // Concurrency

  Future<T> _limited<T>(Future<T> Function() run) async {
    await _slots.acquire();
    try {
      return await run();
    } finally {
      _slots.release();
    }
  }
}

class _Item {
  _Item(this.kind, this.id, this.fileIds);
  final ItemKind kind;
  final String Function(String base) id;
  final List<String> fileIds;
}

class _Group {
  _Group(this.key, this.isShow, this.files);
  final String key;
  final bool isShow;
  final List<IndexedFile> files;
}

/// At most [permits] holders at once.
class _Semaphore {
  _Semaphore(this._free);

  int _free;
  final _waiting = Queue<Completer<void>>();

  Future<void> acquire() {
    if (_free > 0) {
      _free--;
      return Future.value();
    }
    final c = Completer<void>();
    _waiting.add(c);
    return c.future;
  }

  void release() {
    if (_waiting.isNotEmpty) {
      _waiting.removeFirst().complete();
    } else {
      _free++;
    }
  }
}
