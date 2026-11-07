import 'dart:io';
import 'dart:ui' show Locale;

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:player/core/playback/local_playback_progress.dart';
import 'package:player/core/playback/playback_progress_store.dart';
import 'package:player/core/sources/files/files_account.dart';
import 'package:player/core/sources/files/index/file_library_index.dart';
import 'package:player/core/sources/files/match/file_matcher.dart';
import 'package:player/core/sources/files/media_names.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/store/source_records.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/l10n/gen/app_localizations.dart';

import 'fake_media_names.dart';

final filesL10n = lookupAppLocalizations(const Locale('en'));

const filesLocalSource = Source(
  account: ProviderAccount(
    id: kFilesLocalAccountId,
    kind: SourceKind.files,
    displayName: 'This device',
    storageNamespace: 'source/$kFilesLocalAccountId',
    activeProfileId: kOwnerProfileId,
  ),
  profile: SourceProfile(
    id: kOwnerProfileId,
    accountId: kFilesLocalAccountId,
    name: 'Owner',
    isOwner: true,
  ),
  server: SourceServer(
    id: kFilesLocalServerId,
    accountId: kFilesLocalAccountId,
    profileId: kOwnerProfileId,
    name: 'This device',
  ),
);

final filesLocalRecord = SourceAccountRecord(
  account: filesLocalSource.account,
  profiles: [filesLocalSource.profile],
  servers: [filesLocalSource.server],
  addedAtMs: 0,
);

final filesT0 = DateTime.utc(2026, 1, 1);

/// The invented library every files test reads: one root `rmix` holding
///
/// - `Copper Valley (2018)`, TMDB 101, as two files (1080p with an English
///   sidecar, and 2160p in another folder);
/// - `Harbor Lights (2020)`, TMDB 102;
/// - `Glass Orchard`, TMDB 201, S01E01 to S01E03 and S00E01, where TMDB
///   knows only S01E01 and S01E02;
/// - `loose/home video.mkv`, whose name could not be read.
class FilesFixture {
  FilesFixture._(this.dir, this.box, this.index, this.progress);

  final Directory dir;
  final Box<Map<dynamic, dynamic>> box;
  final FileLibraryIndex index;
  final InMemoryPlaybackProgressStore progress;

  static const rootId = 'rmix';
  static const rootPath = '/media/mix';
  static int _n = 0;

  static Future<FilesFixture> create({bool seed = true}) async {
    final dir = await Directory.systemTemp.createTemp('files_fixture');
    Hive.init(dir.path);
    final box = await Hive.openBox<Map<dynamic, dynamic>>('files_${_n++}');
    final index = FileLibraryIndex(box, accountId: kFilesLocalAccountId);
    final f = FilesFixture._(dir, box, index, InMemoryPlaybackProgressStore());
    addTearDown(() async {
      await Hive.close();
      await dir.delete(recursive: true);
    });
    if (seed) await f._seed();
    return f;
  }

  SourceId get sourceId => filesLocalSource.id;

  ItemRef ref(ItemKind kind, String id) =>
      ItemRef(sourceId: sourceId, kind: kind, externalId: id);

  Future<void> addFiles(List<String> paths,
      {String rootId = rootId, DateTime? firstSeen}) async {
    final parsed =
        FakeMediaNames().parseBatch(rootPath, paths, FilesLibraryKind.mixed);
    await index.putFiles([
      for (final p in parsed)
        IndexedFile(
          key: fileKeyFor(rootId, p.path),
          rootId: rootId,
          path: p.path,
          size: 1000,
          modified: filesT0,
          firstSeen: firstSeen ?? filesT0,
          parsed: p,
          sidecars: [
            if (p.path == 'Copper Valley (2018) 1080p.mkv')
              'Copper Valley (2018) 1080p.en.srt',
          ],
        ),
    ]);
  }

  Future<void> _seed() async {
    await index.putRoot(const LibraryRoot(
      id: rootId,
      path: rootPath,
      kind: FilesLibraryKind.mixed,
      title: 'Mixed',
    ));
    await addFiles([
      'Copper Valley (2018) 1080p.mkv',
      'B/Copper Valley (2018) 2160p.mkv',
    ]);
    await addFiles(['Harbor Lights (2020).mkv'],
        firstSeen: filesT0.add(const Duration(days: 2)));
    await addFiles([
      'Glass Orchard/Glass Orchard S01E01.mkv',
      'Glass Orchard/Glass Orchard S01E02.mkv',
      'Glass Orchard/Glass Orchard S01E03.mkv',
      'Glass Orchard/Glass Orchard S00E01.mkv',
    ], firstSeen: filesT0.add(const Duration(days: 1)));
    await index.putFiles([
      IndexedFile(
        key: fileKeyFor(rootId, 'loose/home video.mkv'),
        rootId: rootId,
        path: 'loose/home video.mkv',
        size: 10,
        modified: filesT0,
        firstSeen: filesT0,
      ),
    ]);
    await match('coppervalley|2018', 101);
    await match('harborlights|2020', 102);
    await match('glassorchard|', 201, isShow: true);
    await index.putMovie(const MatchedMovie(
      tmdbId: 101,
      title: 'Copper Valley',
      year: 2018,
      posterPath: '/copper.jpg',
      backdropPath: '/copper-back.jpg',
      runtimeMinutes: 100,
      releaseDate: '2018-03-01',
    ));
    await index.putMovie(const MatchedMovie(
      tmdbId: 102,
      title: 'The Harbor Lights',
      year: 2020,
      releaseDate: '2020-06-01',
    ));
    await index.putShow(const MatchedShow(
      tmdbId: 201,
      title: 'Glass Orchard',
      year: 2021,
      posterPath: '/orchard.jpg',
      seasons: {
        1: [
          MatchedEpisode(season: 1, episode: 1, title: 'Seedlings'),
          MatchedEpisode(season: 1, episode: 2, title: 'Frost'),
        ],
        0: [],
      },
    ));
  }

  Future<void> match(String groupKey, int? tmdbId, {bool isShow = false}) =>
      index.putGroup(GroupMatch(
        groupKey: groupKey,
        isShow: isShow,
        tmdbId: tmdbId,
        matchedAt: filesT0,
      ));

  Future<void> saveProgress(String id, int position, int duration,
          {DateTime? at}) =>
      progress.save(LocalPlaybackProgress(
        sourceId: sourceId.value,
        mediaId: id,
        mediaType: 'movie',
        positionSeconds: position,
        durationSeconds: duration,
        updatedAt: at ?? filesT0,
      ));
}

/// A relay that is always down, unless [movies] or [shows] answer a search.
class FakeFilesRelay extends RelayTmdb {
  FakeFilesRelay() : super();

  bool down = true;
  List<TmdbCandidate> movies = const [];
  List<TmdbCandidate> shows = const [];
  final searched = <String>[];

  @override
  Future<List<TmdbCandidate>> searchMovies(String query, {int? year}) async {
    searched.add('movie:$query');
    if (down) throw RelayUnavailable('down');
    return movies;
  }

  @override
  Future<List<TmdbCandidate>> searchShows(String query, {int? year}) async {
    searched.add('show:$query');
    if (down) throw RelayUnavailable('down');
    return shows;
  }

  @override
  Future<MatchedMovie> movie(int id) async {
    if (down) throw RelayUnavailable('down');
    return MatchedMovie(tmdbId: id, title: 'Pinned $id');
  }

  @override
  Future<MatchedShow> show(int id, {required Iterable<int> seasons}) async {
    if (down) throw RelayUnavailable('down');
    return MatchedShow(tmdbId: id, title: 'Pinned $id');
  }
}
