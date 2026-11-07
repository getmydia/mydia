import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:player/core/playback/local_playback_progress.dart';
import 'package:player/core/playback/playback_progress_store.dart';
import 'package:player/core/sources/files/files_ids.dart';
import 'package:player/core/sources/files/index/file_library_index.dart';
import 'package:player/core/sources/files/match/file_matcher.dart';
import 'package:player/core/sources/files/media_names.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/domain/sources/item.dart';

import '../fake_media_names.dart';

class FakeRelay extends RelayTmdb {
  FakeRelay() : super();

  bool down = false;
  final searches = <String>[];
  final showSeasons = <List<int>>[];
  int inFlight = 0;
  int maxInFlight = 0;
  Duration delay = Duration.zero;
  final Map<String, int> ids = {};

  /// The year each search asked for, shows under `tv:`.
  final searchYears = <String, int?>{};

  /// Titles a search returns besides [ids], each with the id given.
  final Map<String, int> extra = {};

  /// When set, every call waits for it.
  Completer<void>? gate;

  Future<T> _call<T>(T Function() body) async {
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    try {
      await Future<void>.delayed(delay);
      await gate?.future;
      if (down) throw RelayUnavailable('down');
      return body();
    } finally {
      inFlight--;
    }
  }

  @override
  Future<List<TmdbCandidate>> searchMovies(String query, {int? year}) =>
      _search(query, year);

  Future<List<TmdbCandidate>> _search(String query, int? year,
          {String label = ''}) =>
      _call(() {
        searches.add(query);
        searchYears['$label$query'] = year;
        final id = ids[query];
        return [
          if (id != null) TmdbCandidate(id: id, title: query, year: year),
          for (final e in extra.entries)
            TmdbCandidate(id: e.value, title: e.key, year: year),
        ];
      });

  @override
  Future<List<TmdbCandidate>> searchShows(String query, {int? year}) =>
      _search(query, year, label: 'tv:');

  @override
  Future<MatchedMovie> movie(int id) =>
      _call(() => MatchedMovie(tmdbId: id, title: 'M$id'));

  @override
  Future<MatchedShow> show(int id, {required Iterable<int> seasons}) =>
      _call(() {
        showSeasons.add(seasons.toList()..sort());
        return MatchedShow(tmdbId: id, title: 'S$id', seasons: {
          for (final s in seasons) s: [MatchedEpisode(season: s, episode: 1)],
        });
      });
}

void main() {
  late Directory dir;
  late FileLibraryIndex index;
  late InMemoryPlaybackProgressStore progress;
  late FakeRelay relay;
  late int landed;
  late FileMatcher matcher;
  var n = 0;
  const source = SourceId('files-1');
  final t0 = DateTime.fromMillisecondsSinceEpoch(1700000000000);

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('file_matcher_test');
    Hive.init(dir.path);
    final box = await Hive.openBox<Map<dynamic, dynamic>>('m_${n++}');
    index = FileLibraryIndex(box, accountId: 'a');
    progress = InMemoryPlaybackProgressStore();
    relay = FakeRelay();
    landed = 0;
    matcher = FileMatcher(
      tmdb: relay,
      names: FakeMediaNames(),
      index: index,
      progress: progress,
      sourceId: source,
      onGroupLanded: () async => landed++,
      now: () => t0.add(const Duration(days: 1)),
    );
  });

  tearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  Future<void> addFiles(List<String> paths) async {
    final parsed =
        FakeMediaNames().parseBatch('', paths, FilesLibraryKind.mixed);
    await index.putFiles([
      for (final p in parsed)
        IndexedFile(
          key: fileKeyFor('r', p.path),
          rootId: 'r',
          path: p.path,
          size: 1,
          modified: t0,
          firstSeen: t0,
          parsed: p,
        ),
    ]);
  }

  ItemRef ref(ItemKind kind, String id) =>
      ItemRef(sourceId: source, kind: kind, externalId: id);

  Future<void> saveProgress(ItemKind kind, String id, String type) =>
      progress.save(LocalPlaybackProgress(
        sourceId: source.value,
        mediaId: id,
        mediaType: type,
        positionSeconds: 60,
        durationSeconds: 600,
        updatedAt: t0,
      ));

  test('two_files_of_one_movie_make_one_group', () async {
    relay.ids['Copper Valley'] = 7;
    await addFiles([
      'A/Copper Valley (2018) 1080p.mkv',
      'B/Copper Valley (2018) 2160p.mkv',
    ]);
    await matcher.matchPending();
    expect(relay.searches, ['Copper Valley']);
    expect(index.movie(7), isNotNull);
    expect(index.group('coppervalley|2018')!.tmdbId, 7);
  });

  test('episodes_group_by_show_and_fetch_their_seasons', () async {
    relay.ids['Moon Harbor'] = 3;
    await addFiles([
      'Moon Harbor S01E01.mkv',
      'Moon Harbor S01E02.mkv',
      'Moon Harbor S03E01.mkv',
    ]);
    await matcher.matchPending();
    expect(relay.searches, ['Moon Harbor']);
    expect(relay.showSeasons, [
      [1, 3],
    ]);
    expect(index.show(3)!.seasons.keys, unorderedEquals([1, 3]));
    expect(index.group('tv:moonharbor|')!.isShow, isTrue);
  });

  test('never_more_than_four_requests_in_flight', () async {
    relay.delay = const Duration(milliseconds: 5);
    await addFiles([for (var i = 0; i < 10; i++) 'Title$i (2000).mkv']);
    await matcher.matchPending();
    expect(relay.searches.length, 10);
    expect(relay.maxInFlight, lessThanOrEqualTo(4));
    expect(relay.maxInFlight, greaterThan(1));
  });

  test('pinned_group_is_not_searched_again', () async {
    relay.ids['Copper Valley'] = 7;
    await addFiles(['Copper Valley (2018).mkv']);
    await index.putGroup(GroupMatch(
      groupKey: 'coppervalley|2018',
      isShow: false,
      tmdbId: 99,
      pinned: true,
      matchedAt: t0.subtract(const Duration(days: 5)),
    ));
    await matcher.matchPending();
    expect(relay.searches, isEmpty);
    expect(index.group('coppervalley|2018')!.tmdbId, 99);
  });

  test('pinned show still fetches seasons it lacks', () async {
    await addFiles(['Moon Harbor S02E01.mkv']);
    await index.putGroup(GroupMatch(
      groupKey: 'tv:moonharbor|',
      isShow: true,
      tmdbId: 3,
      pinned: true,
      matchedAt: t0,
    ));
    await matcher.matchPending();
    expect(relay.searches, isEmpty);
    expect(relay.showSeasons, [
      [2],
    ]);
    expect(index.show(3)!.seasons.keys, [2]);
  });

  test('relay_down_leaves_group_provisional_then_migrates_progress', () async {
    relay.ids['Copper Valley'] = 7;
    await addFiles(['Copper Valley (2018).mkv']);
    final p = provisionalKey('coppervalley|2018');
    await saveProgress(ItemKind.movie, movieId(p), 'movie');
    await index.setWatched(movieId(p), true);

    relay.down = true;
    await matcher.matchPending();
    expect(index.group('coppervalley|2018'), isNull);
    expect(landed, 0);
    expect(progress.get(progressKey(ref(ItemKind.movie, p))), isNotNull);

    relay.down = false;
    await matcher.matchPending();
    final moved = progress.get(progressKey(ref(ItemKind.movie, '7')));
    expect(moved!.positionSeconds, 60);
    expect(moved.mediaId, '7');
    expect(progress.get(progressKey(ref(ItemKind.movie, p))), isNull);
    expect(index.watched(), contains('7'));
    expect(index.watched(), isNot(contains(p)));
  });

  test('provisional episode progress migrates', () async {
    relay.ids['Moon Harbor'] = 3;
    await addFiles(['Moon Harbor S01E02.mkv']);
    final p = provisionalKey('tv:moonharbor|');
    await saveProgress(ItemKind.episode, episodeId(p, 1, 2), 'episode');
    await matcher.matchPending();
    expect(
      progress.get(progressKey(ref(ItemKind.episode, '3-1-2'))),
      isNotNull,
    );
    expect(
      progress.get(progressKey(ref(ItemKind.episode, episodeId(p, 1, 2)))),
      isNull,
    );
  });

  test('below_threshold_is_unmatched_not_provisional', () async {
    await addFiles(['Copper Valley (2018).mkv']);
    await matcher.matchPending();
    final g = index.group('coppervalley|2018')!;
    expect(g.tmdbId, isNull);
    expect(g.pinned, isFalse);
  });

  test('unmatch_pin_moves_files_to_folders', () async {
    relay.ids['Copper Valley'] = 7;
    await addFiles(['Copper Valley (2018).mkv']);
    await matcher.matchPending();
    await matcher.pin('coppervalley|2018', isShow: false);
    final g = index.group('coppervalley|2018')!;
    expect((g.tmdbId, g.pinned), (null, true));
    relay.searches.clear();
    await matcher.matchPending();
    expect(relay.searches, isEmpty);
  });

  test('pin to an id fetches details and migrates from the old id', () async {
    relay.ids['Copper Valley'] = 7;
    await addFiles(['Copper Valley (2018).mkv']);
    await matcher.matchPending();
    await saveProgress(ItemKind.movie, '7', 'movie');
    await matcher.pin('coppervalley|2018', isShow: false, tmdbId: 8);
    expect(index.movie(8), isNotNull);
    expect(progress.get(progressKey(ref(ItemKind.movie, '8'))), isNotNull);
    expect(progress.get(progressKey(ref(ItemKind.movie, '7'))), isNull);
    expect(index.group('coppervalley|2018')!.pinned, isTrue);
  });

  test('on_group_landed_fires_once_per_group', () async {
    relay.ids['Copper Valley'] = 7;
    await addFiles([
      'Copper Valley (2018).mkv',
      'Other (2000).mkv',
      'Moon Harbor S01E01.mkv',
    ]);
    await matcher.matchPending();
    expect(landed, 3);
    await matcher.matchPending();
    expect(landed, 3);
  });

  test('a failing group does not stop the others', () async {
    relay.ids['Copper Valley'] = 7;
    await addFiles(['Copper Valley (2018).mkv', 'Other (2000).mkv']);
    final failing = _FailsFor(relay, 'Other');
    final m = FileMatcher(
      tmdb: failing,
      names: FakeMediaNames(),
      index: index,
      progress: progress,
      sourceId: source,
    );
    await m.matchPending();
    expect(index.group('coppervalley|2018')!.tmdbId, 7);
    expect(index.group('other|2000'), isNull);
  });

  String fkey(String path) => fileKeyFor('r', path);

  test('unmatched file progress moves to the movie id on pin', () async {
    await addFiles(['Copper Valley (2018).mkv']);
    await matcher.matchPending();
    expect(index.group('coppervalley|2018')!.tmdbId, isNull);
    final fid = unmatchedFileId(fkey('Copper Valley (2018).mkv'));
    await saveProgress(ItemKind.video, fid, 'movie');
    await index.setWatched(fid, true);
    await matcher.pin('coppervalley|2018', isShow: false, tmdbId: 7);
    expect(progress.get(progressKey(ref(ItemKind.movie, '7'))), isNotNull);
    expect(progress.get(progressKey(ref(ItemKind.video, fid))), isNull);
    expect(index.watched(), contains('7'));
    expect(index.watched(), isNot(contains(fid)));
  });

  test('unmatching copies movie progress to every file id', () async {
    relay.ids['Copper Valley'] = 7;
    await addFiles(
        ['A/Copper Valley (2018).mkv', 'B/Copper Valley (2018).mkv']);
    await matcher.matchPending();
    await saveProgress(ItemKind.movie, '7', 'movie');
    await index.setWatched('7', true);
    await matcher.pin('coppervalley|2018', isShow: false);
    for (final p in [
      'A/Copper Valley (2018).mkv',
      'B/Copper Valley (2018).mkv'
    ]) {
      final id = unmatchedFileId(fkey(p));
      expect(progress.get(progressKey(ref(ItemKind.video, id))), isNotNull);
      expect(index.watched(), contains(id));
    }
    expect(progress.get(progressKey(ref(ItemKind.movie, '7'))), isNull);
  });

  test('unmatching an episode moves progress to its file id', () async {
    relay.ids['Moon Harbor'] = 3;
    await addFiles(['Moon Harbor S01E02.mkv']);
    await matcher.matchPending();
    await saveProgress(ItemKind.episode, '3-1-2', 'episode');
    await matcher.pin('tv:moonharbor|', isShow: true);
    final id = unmatchedFileId(fkey('Moon Harbor S01E02.mkv'));
    expect(progress.get(progressKey(ref(ItemKind.video, id))), isNotNull);
  });

  test('multi-episode file migrates every episode in its range', () async {
    relay.ids['Moon Harbor'] = 3;
    const parsed = ParsedName(
      path: 'Moon Harbor S01E01E02.mkv',
      isEpisode: true,
      title: 'Moon Harbor',
      groupKey: 'tv:moonharbor|',
      season: 1,
      episode: 1,
      episodeEnd: 2,
    );
    await index.putFiles([
      IndexedFile(
        key: fkey(parsed.path),
        rootId: 'r',
        path: parsed.path,
        size: 1,
        modified: t0,
        firstSeen: t0,
        parsed: parsed,
      ),
    ]);
    final p = provisionalKey('tv:moonharbor|');
    await saveProgress(ItemKind.episode, episodeId(p, 1, 1), 'episode');
    await saveProgress(ItemKind.episode, episodeId(p, 1, 2), 'episode');
    await matcher.matchPending();
    expect(
        progress.get(progressKey(ref(ItemKind.episode, '3-1-1'))), isNotNull);
    expect(
        progress.get(progressKey(ref(ItemKind.episode, '3-1-2'))), isNotNull);
  });

  test('migration keeps the newer record at the target', () async {
    relay.ids['Copper Valley'] = 7;
    await addFiles(['Copper Valley (2018).mkv']);
    final p = provisionalKey('coppervalley|2018');
    await saveProgress(ItemKind.movie, p, 'movie');
    await progress.save(LocalPlaybackProgress(
      sourceId: source.value,
      mediaId: '7',
      mediaType: 'movie',
      positionSeconds: 500,
      durationSeconds: 600,
      updatedAt: t0.add(const Duration(hours: 1)),
    ));
    await matcher.matchPending();
    expect(
      progress.get(progressKey(ref(ItemKind.movie, '7')))!.positionSeconds,
      500,
    );
    expect(progress.get(progressKey(ref(ItemKind.movie, p))), isNull);
  });

  test('a show with a season TMDB lacks still matches', () async {
    relay.ids['Moon Harbor'] = 3;
    final m = FileMatcher(
      tmdb: _EmptySeason(relay, 0),
      names: FakeMediaNames(),
      index: index,
      progress: progress,
      sourceId: source,
    );
    await addFiles(['Moon Harbor S00E01.mkv', 'Moon Harbor S01E01.mkv']);
    await m.matchPending();
    expect(index.group('tv:moonharbor|')!.tmdbId, 3);
    expect(index.show(3)!.seasons.keys, unorderedEquals([0, 1]));
  });

  test('rematching a show leaves the movie with its TMDB number alone',
      () async {
    relay.ids['Copper Valley'] = 7;
    relay.ids['Moon Harbor'] = 7;
    await addFiles(['Copper Valley (2018).mkv', 'Moon Harbor S01E01.mkv']);
    await matcher.matchPending();
    expect(index.group('coppervalley|2018')!.tmdbId, 7);
    expect(index.group('tv:moonharbor|')!.tmdbId, 7);
    await saveProgress(ItemKind.movie, '7', 'movie');
    await index.setWatched('7', true);

    await matcher.pin('tv:moonharbor|', isShow: true, tmdbId: 8);

    expect(progress.get(progressKey(ref(ItemKind.movie, '7'))), isNotNull);
    expect(progress.get(progressKey(ref(ItemKind.show, '8'))), isNull);
    expect(index.watched(), contains('7'));
    expect(index.watched(), isNot(contains('8')));
  });

  test('candidates_below_the_threshold_leave_the_group_unmatched', () async {
    relay.extra['Some Other Film'] = 41;
    await addFiles(['Copper Valley (2018).mkv']);
    await matcher.matchPending();
    final g = index.group('coppervalley|2018')!;
    expect(g.tmdbId, isNull);
    expect(g.pinned, isFalse);
    expect(index.movie(41), isNull);
  });

  test('a provisional group searched with no winner hands its state to files',
      () async {
    await addFiles(['Copper Valley (2018).mkv']);
    final p = provisionalKey('coppervalley|2018');
    await saveProgress(ItemKind.movie, movieId(p), 'movie');
    await index.setWatched(movieId(p), true);

    await matcher.matchPending();

    final fid = unmatchedFileId(fkey('Copper Valley (2018).mkv'));
    expect(index.group('coppervalley|2018')!.tmdbId, isNull);
    expect(progress.get(progressKey(ref(ItemKind.video, fid)))!.positionSeconds,
        60);
    expect(progress.get(progressKey(ref(ItemKind.movie, p))), isNull);
    expect(index.watched(), contains(fid));
    expect(index.watched(), isNot(contains(p)));
  });

  test('a multi-episode file hands its state to every episode on match',
      () async {
    const parsed = ParsedName(
      path: 'Moon Harbor S01E01E02.mkv',
      isEpisode: true,
      title: 'Moon Harbor',
      groupKey: 'tv:moonharbor|',
      season: 1,
      episode: 1,
      episodeEnd: 2,
    );
    await index.putFiles([
      IndexedFile(
        key: fkey(parsed.path),
        rootId: 'r',
        path: parsed.path,
        size: 1,
        modified: t0,
        firstSeen: t0,
        parsed: parsed,
      ),
    ]);
    await matcher.matchPending();
    expect(index.group('tv:moonharbor|')!.tmdbId, isNull);
    final fid = unmatchedFileId(fkey(parsed.path));
    await saveProgress(ItemKind.video, fid, 'episode');
    await index.setWatched(fid, true);

    await matcher.pin('tv:moonharbor|', isShow: true, tmdbId: 3);

    for (final id in ['3-1-1', '3-1-2']) {
      expect(progress.get(progressKey(ref(ItemKind.episode, id))), isNotNull,
          reason: id);
      expect(index.watched(), contains(id));
    }
    expect(progress.get(progressKey(ref(ItemKind.video, fid))), isNull);
  });

  test('a show search leaves the year to the scorer', () async {
    relay.ids['Moon Harbor'] = 3;
    relay.ids['Copper Valley'] = 7;
    await addFiles(
        ['Moon Harbor (2019) S02E01.mkv', 'Copper Valley (2018).mkv']);
    await matcher.matchPending();
    expect(relay.searchYears['tv:Moon Harbor'], isNull);
    expect(relay.searchYears['Copper Valley'], 2018);
    expect(index.group('tv:moonharbor|2019')!.tmdbId, 3);
  });

  test('a pin made while the search runs is not overwritten', () async {
    relay.ids['Copper Valley'] = 7;
    await addFiles(['Copper Valley (2018).mkv']);
    relay.gate = Completer<void>();
    final pending = matcher.matchPending();
    await Future<void>.delayed(Duration.zero);

    await matcher.pin('coppervalley|2018', isShow: false);
    relay.gate!.complete();
    await pending;

    final g = index.group('coppervalley|2018')!;
    expect((g.tmdbId, g.pinned), (null, true));
  });

  test('a pin made while progress migrates is not overwritten', () async {
    relay.ids['Copper Valley'] = 7;
    await addFiles(['Copper Valley (2018).mkv']);
    final gated = _FirstSaveHeld();
    final m = FileMatcher(
      tmdb: relay,
      names: FakeMediaNames(),
      index: index,
      progress: gated,
      sourceId: source,
      now: () => t0.add(const Duration(days: 1)),
    );
    final p = provisionalKey('coppervalley|2018');
    await gated.save(LocalPlaybackProgress(
      sourceId: source.value,
      mediaId: p,
      mediaType: 'movie',
      positionSeconds: 60,
      durationSeconds: 600,
      updatedAt: t0,
    ));
    gated.holdNext();

    final pending = m.matchPending();
    // The automatic match is now inside its migration, holding a save.
    await gated.held.future;

    await m.pin('coppervalley|2018', isShow: false, tmdbId: 8);
    gated.release();
    await pending;

    final g = index.group('coppervalley|2018')!;
    expect((g.tmdbId, g.pinned), (8, true));
    expect(gated.get(progressKey(ref(ItemKind.movie, '8'))), isNotNull);
  });

  test('rematching one of two groups on a movie copies its state', () async {
    relay.ids['Copper Valley'] = 7;
    await addFiles(['A/Copper Valley (2018).mkv', 'B/Copper Valley.mkv']);
    await matcher.matchPending();
    expect(index.group('coppervalley|2018')!.tmdbId, 7);
    expect(index.group('coppervalley|')!.tmdbId, 7);
    await saveProgress(ItemKind.movie, '7', 'movie');
    await index.setWatched('7', true);

    await matcher.pin('coppervalley|', isShow: false, tmdbId: 8);

    expect(progress.get(progressKey(ref(ItemKind.movie, '7'))), isNotNull);
    expect(index.watched(), contains('7'));
    expect(progress.get(progressKey(ref(ItemKind.movie, '8'))), isNotNull);
    expect(index.watched(), contains('8'));
  });
}

/// Holds the next save after [holdNext] until [release]; [held] completes
/// once that save has started.
class _FirstSaveHeld extends InMemoryPlaybackProgressStore {
  Completer<void>? _gate;
  final held = Completer<void>();

  void holdNext() => _gate = Completer<void>();
  void release() => _gate?.complete();

  @override
  Future<void> save(LocalPlaybackProgress progress) async {
    final gate = _gate;
    if (gate != null && !held.isCompleted) {
      held.complete();
      await gate.future;
    }
    return super.save(progress);
  }
}

class _FailsFor extends RelayTmdb {
  _FailsFor(this.inner, this.title) : super();
  final FakeRelay inner;
  final String title;

  @override
  Future<List<TmdbCandidate>> searchMovies(String query, {int? year}) {
    if (query == title) throw RelayUnavailable('x');
    return inner.searchMovies(query, year: year);
  }

  @override
  Future<MatchedMovie> movie(int id) => inner.movie(id);
}

class _EmptySeason extends RelayTmdb {
  _EmptySeason(this.inner, this.empty) : super();
  final FakeRelay inner;
  final int empty;

  @override
  Future<List<TmdbCandidate>> searchShows(String query, {int? year}) =>
      inner.searchShows(query, year: year);

  @override
  Future<MatchedShow> show(int id, {required Iterable<int> seasons}) async {
    final s = await inner.show(id, seasons: seasons);
    return MatchedShow(tmdbId: id, title: s.title, seasons: {
      for (final e in s.seasons.entries) e.key: e.key == empty ? [] : e.value,
    });
  }
}
