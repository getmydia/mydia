import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:player/core/sources/files/index/file_library_index.dart';
import 'package:player/core/sources/files/media_names.dart';

void main() {
  late Directory dir;
  late Box<Map<dynamic, dynamic>> box;
  var n = 0;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('files_index_test');
    Hive.init(dir.path);
    box = await Hive.openBox<Map<dynamic, dynamic>>('files_index_${n++}');
  });

  tearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  final t = DateTime.fromMillisecondsSinceEpoch(1700000000000);

  IndexedFile file(String root, String path, {bool parsed = false}) =>
      IndexedFile(
        key: fileKeyFor(root, path),
        rootId: root,
        path: path,
        size: 10,
        modified: t,
        firstSeen: t,
        parsed: parsed
            ? const ParsedName(
                path: 'a.mkv',
                isEpisode: true,
                title: 'Moon Harbor',
                groupKey: 'moon harbor',
                year: 2001,
                season: 1,
                episode: 2,
                episodeEnd: 3,
              )
            : null,
        sidecars: const ['a.srt'],
      );

  test('fileKeyFor is 16 lowercase hex chars and stable', () {
    final k = fileKeyFor('r1', 'a/b.mkv');
    expect(k, matches(RegExp(r'^[0-9a-f]{16}$')));
    expect(k, fileKeyFor('r1', 'a/b.mkv'));
    expect(k, isNot(fileKeyFor('r2', 'a/b.mkv')));
  });

  test('roundtrips_every_record_type', () async {
    final a = FileLibraryIndex(box, accountId: 'a');
    await a.putRoot(const LibraryRoot(
        id: 'r1', path: '/m', kind: FilesLibraryKind.mixed, title: 'Media'));
    final f = file('r1', 'x/a.mkv', parsed: true);
    await a.putFiles([f]);
    await a.putGroup(GroupMatch(
        groupKey: 'g', isShow: true, tmdbId: 5, pinned: true, matchedAt: t));
    await a.putMovie(const MatchedMovie(
        tmdbId: 1, title: 'Tide', year: 1999, runtimeMinutes: 90));
    await a.putShow(const MatchedShow(tmdbId: 2, title: 'Harbor', seasons: {
      1: [MatchedEpisode(season: 1, episode: 1, title: 'Pilot')],
      2: [MatchedEpisode(season: 2, episode: 4, runtimeMinutes: 40)],
    }));
    await a.setWatched('550', true);
    await a.setWatched('f1', true);
    await a.setWatched('f1', false);
    await a.setLastScanAt(t);

    final b = FileLibraryIndex(box, accountId: 'a');
    expect(b.roots().single.kind, FilesLibraryKind.mixed);
    final got = b.files()[f.key]!;
    expect(got.parsed!.episodeEnd, 3);
    expect(got.parsed!.title, 'Moon Harbor');
    expect(got.sidecars, ['a.srt']);
    expect(got.modified, t);
    expect(b.group('g')!.pinned, isTrue);
    expect(b.group('g')!.tmdbId, 5);
    expect(b.movie(1)!.runtimeMinutes, 90);
    expect(b.show(2)!.seasons[2]!.single.episode, 4);
    expect(b.show(2)!.seasons[1]!.single.title, 'Pilot');
    expect(b.watched(), {'550'});
    expect(b.lastScanAt(), t);
  });

  test('accounts_do_not_see_each_other', () async {
    final a = FileLibraryIndex(box, accountId: 'a');
    await a.putMovie(const MatchedMovie(tmdbId: 1, title: 'Tide'));
    await a.setWatched('1', true);
    final b = FileLibraryIndex(box, accountId: 'b');
    expect(b.movie(1), isNull);
    expect(b.watched(), isEmpty);
  });

  test('remove_root_drops_its_files_only', () async {
    final a = FileLibraryIndex(box, accountId: 'a');
    await a.putRoot(const LibraryRoot(
        id: 'r1', path: '/m', kind: FilesLibraryKind.movies, title: 'M'));
    await a.putRoot(const LibraryRoot(
        id: 'r2', path: '/s', kind: FilesLibraryKind.series, title: 'S'));
    final f1 = file('r1', 'a.mkv');
    final f2 = file('r2', 'b.mkv');
    await a.putFiles([f1, f2]);
    await a.removeRoot('r1');
    expect(a.files().keys, [f2.key]);
    expect(a.roots().single.id, 'r2');
    final b = FileLibraryIndex(box, accountId: 'a');
    expect(b.files().keys, [f2.key]);
    expect(b.roots().single.id, 'r2');
  });

  test('clear_removes_only_this_account', () async {
    final a = FileLibraryIndex(box, accountId: 'a');
    final b = FileLibraryIndex(box, accountId: 'b');
    await a.putMovie(const MatchedMovie(tmdbId: 1, title: 'Tide'));
    await b.putMovie(const MatchedMovie(tmdbId: 1, title: 'Tide'));
    await a.setLastScanAt(t);
    await a.clear();
    expect(a.movie(1), isNull);
    expect(a.lastScanAt(), isNull);
    expect(FileLibraryIndex(box, accountId: 'a').movie(1), isNull);
    expect(FileLibraryIndex(box, accountId: 'b').movie(1), isNotNull);
  });

  test('unreadable_record_is_skipped_not_thrown', () async {
    final a = FileLibraryIndex(box, accountId: 'a');
    await a.putMovie(const MatchedMovie(tmdbId: 1, title: 'Tide'));
    await box.put('a/movie/2', {'tmdbId': 'oops'});
    await box.put('a/root/r', {'id': 1});
    await box.put('a/file/zz', {});
    await box.put('a/movie/notanint', {'tmdbId': 3, 'title': 'x'});
    final b = FileLibraryIndex(box, accountId: 'a');
    expect(b.movie(1), isNotNull);
    expect(b.movie(2), isNull);
    expect(b.roots(), isEmpty);
    expect(b.files(), isEmpty);
  });

  test('a_season_with_no_episodes_survives_a_reload', () async {
    final a = FileLibraryIndex(box, accountId: 'a');
    await a.putShow(const MatchedShow(tmdbId: 2, title: 'Harbor', seasons: {
      0: [],
      1: [MatchedEpisode(season: 1, episode: 1)],
    }));
    final b = FileLibraryIndex(box, accountId: 'a');
    expect(b.show(2)!.seasons.keys, unorderedEquals([0, 1]));
    expect(b.show(2)!.seasons[0], isEmpty);
  });

  test('a_show_stored_without_season_numbers_still_loads', () async {
    await box.put('a/show/3', {
      'tmdbId': 3,
      'title': 'Older',
      'episodes': [
        {'season': 1, 'episode': 1},
      ],
    });
    final b = FileLibraryIndex(box, accountId: 'a');
    expect(b.show(3)!.seasons.keys, [1]);
  });

  test('a_file_write_that_fails_leaves_memory_unchanged', () async {
    final a = FileLibraryIndex(_FailingPutAll(box), accountId: 'a');
    await expectLater(
      a.putFiles([file('r1', 'a.mkv')]),
      throwsA(isA<HiveError>()),
    );
    expect(a.files(), isEmpty);
  });

  test('parsed_as_round_trips', () async {
    final a = FileLibraryIndex(box, accountId: 'a');
    final f = file('r1', 'a.mkv');
    await a.putFiles([
      IndexedFile(
        key: f.key,
        rootId: f.rootId,
        path: f.path,
        size: f.size,
        modified: f.modified,
        firstSeen: f.firstSeen,
        parsedAs: FilesLibraryKind.series,
      ),
    ]);
    final b = FileLibraryIndex(box, accountId: 'a');
    expect(b.files()[f.key]!.parsedAs, FilesLibraryKind.series);
  });
}

/// A box whose batch write fails, as a full disk would.
class _FailingPutAll implements Box<Map<dynamic, dynamic>> {
  _FailingPutAll(this._inner);

  final Box<Map<dynamic, dynamic>> _inner;

  @override
  Iterable<dynamic> get keys => _inner.keys;

  @override
  Future<void> putAll(Map<dynamic, Map<dynamic, dynamic>> entries) =>
      Future.error(HiveError('disk full'));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
