import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:player/core/p2p/peer_files_wire.dart';
import 'package:player/core/sources/files/index/file_library_index.dart';
import 'package:player/core/sources/files/media_names.dart';

void main() {
  final t = DateTime.fromMillisecondsSinceEpoch(1700000000000);

  test('pageIndex keeps the wire order and puts an oversized record alone',
      () async {
    final dir = await Directory.systemTemp.createTemp('peer_files_wire_test');
    Hive.init(dir.path);
    addTearDown(() async {
      await Hive.close();
      await dir.delete(recursive: true);
    });
    final box = await Hive.openBox<Map<dynamic, dynamic>>('wire_index');
    final index = FileLibraryIndex(box, accountId: 'a');
    await index.putRoot(const LibraryRoot(
        id: 'r1', path: '/m', kind: FilesLibraryKind.movies, title: 'm'));
    await index.putMovie(const MatchedMovie(tmdbId: 2, title: 'Paper Comet'));
    await index.putMovie(const MatchedMovie(tmdbId: 1, title: 'Tin Sparrow'));

    // A budget smaller than any record: one record per page.
    final pages = pageIndex(index, budget: 1);
    expect(pages, hasLength(3));
    expect(
        decodeJsonRecords(pages[0].roots, LibraryRoot.fromMap).single.id, 'r1');
    expect([
      for (final p in pages.skip(1))
        decodeJsonRecords(p.movies, MatchedMovie.fromMap).single.tmdbId,
    ], [
      1,
      2
    ]);

    expect(pageIndex(index), hasLength(1));
  });

  group('records_round_trip', () {
    test('LibraryRoot', () {
      const root = LibraryRoot(
        id: 'r1',
        path: '/media/films',
        kind: FilesLibraryKind.movies,
        title: 'Films',
      );
      final back = decodeJsonRecords(
              encodeJsonRecords([root], (r) => r.toMap()), LibraryRoot.fromMap)
          .single;
      expect(back.toMap(), root.toMap());
    });

    test('IndexedFile', () {
      final file = IndexedFile(
        key: fileKeyFor('r1', 'The Copper Lantern (2011).mkv'),
        rootId: 'r1',
        path: 'The Copper Lantern (2011).mkv',
        size: 123456789012,
        modified: t,
        firstSeen: t,
        parsed: const ParsedName(
          path: 'The Copper Lantern (2011).mkv',
          isEpisode: false,
          title: 'The Copper Lantern',
          groupKey: 'thecopperlantern|2011',
          year: 2011,
        ),
        sidecars: const ['The Copper Lantern (2011).en.srt'],
        parsedAs: FilesLibraryKind.movies,
      );
      final back = decodeJsonRecords(
              encodeJsonRecords([file], (f) => f.toMap()), IndexedFile.fromMap)
          .single;
      expect(back.toMap(), file.toMap());
    });

    test('GroupMatch', () {
      final group = GroupMatch(
        groupKey: 'thecopperlantern|2011',
        isShow: false,
        tmdbId: 9001,
        pinned: true,
        matchedAt: t,
        pinRevision: 42,
      );
      final back = decodeJsonRecords(
              encodeJsonRecords([group], (g) => g.toMap()), GroupMatch.fromMap)
          .single;
      expect(back.toMap(), group.toMap());
    });

    test('MatchedMovie', () {
      const movie = MatchedMovie(
        tmdbId: 9001,
        title: 'The Copper Lantern',
        year: 2011,
        overview: 'A lamp-lighter keeps a harbor town awake.',
        posterPath: '/lantern.jpg',
        runtimeMinutes: 97,
        releaseDate: '2011-04-01',
      );
      final back = decodeJsonRecords(
              encodeJsonRecords([movie], (m) => m.toMap()),
              MatchedMovie.fromMap)
          .single;
      expect(back.toMap(), movie.toMap());
    });

    test('MatchedShow, with its episodes', () {
      const show = MatchedShow(
        tmdbId: 9100,
        title: 'Saltmarsh Choir',
        year: 2019,
        seasons: {
          1: [
            MatchedEpisode(season: 1, episode: 1, title: 'Low Tide'),
            MatchedEpisode(season: 1, episode: 2, runtimeMinutes: 44),
          ],
          2: [],
        },
      );
      final back = decodeJsonRecords(
              encodeJsonRecords([show], (s) => s.toMap()), MatchedShow.fromMap)
          .single;
      expect(back.toMap(), show.toMap());
      expect(back.seasons.keys, unorderedEquals([1, 2]));
    });
  });
}
