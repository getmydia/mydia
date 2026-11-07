import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/cache/invalidation_target.dart';
import 'package:player/core/sources/cache/source_rules.dart';
import 'package:player/core/sources/files/backend/file_system_backend.dart';
import 'package:player/core/sources/files/files_ids.dart';
import 'package:player/core/sources/files/files_media_source.dart';
import 'package:player/core/sources/files/index/file_library_index.dart';
import 'package:player/core/sources/files/match/file_matcher.dart';
import 'package:player/core/sources/files/media_names.dart';
import 'package:player/core/sources/media_source.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/domain/sources/library.dart';

import '../media_source_contract.dart';
import 'fake_backend.dart';
import 'fake_media_names.dart';
import 'files_fixture.dart';

class _Built {
  _Built(this.fixture, this.source, this.backend, this.relay);
  final FilesFixture fixture;
  final FilesMediaSource source;
  final FakeBackend backend;
  final FakeFilesRelay relay;
  var reauth = 0;
  final invalidated = <InvalidationTarget>[];
}

Future<_Built> _build({BackendFailure? probeFailure}) async {
  final f = await FilesFixture.create();
  final backend = FakeBackend(const {}, probeFailure: probeFailure);
  final relay = FakeFilesRelay();
  late final _Built built;
  final matcher = FileMatcher(
    tmdb: relay,
    names: FakeMediaNames(),
    index: f.index,
    progress: f.progress,
    sourceId: f.sourceId,
  );
  final source = FilesMediaSource(
    source: filesLocalSource,
    backend: backend,
    index: f.index,
    progress: f.progress,
    matcher: matcher,
    tmdb: relay,
    onReauthNeeded: () => built.reauth++,
    invalidate: (targets) async => built.invalidated.addAll(targets),
    l10n: () => filesL10n,
  );
  addTearDown(source.dispose);
  built = _Built(f, source, backend, relay);
  return built;
}

const _movie = '101';
const _show = '201';
final _root =
    LibraryRef(sourceId: filesLocalSource.id, id: FilesFixture.rootId);
final _folders =
    LibraryRef(sourceId: filesLocalSource.id, id: kFilesFoldersLibraryId);

void main() {
  runMediaSourceContract('Files', () async {
    final b = await _build();
    final f = b.fixture;
    return ContractFixture(
      source: b.source,
      library: _root,
      playable: f.ref(ItemKind.movie, _movie),
      libraryItemCount: 3,
      show: f.ref(ItemKind.show, _show),
    );
  });

  test('movie_versions_are_its_files_with_sidecar_subtitles', () async {
    final b = await _build();
    final detail = await b.source.item(b.fixture.ref(ItemKind.movie, _movie));
    expect(detail.versions, hasLength(2));
    final hd = detail.versions.firstWhere((v) => v.streams.isNotEmpty);
    expect(hd.id,
        fileKeyFor(FilesFixture.rootId, 'Copper Valley (2018) 1080p.mkv'));
    expect(hd.container, 'mkv');
    expect(hd.sizeBytes, 1000);
    expect(hd.durationSeconds, 6000);
    final sub = hd.streams.single;
    expect(sub.kind, MediaStreamKind.subtitle);
    expect(sub.language, 'en');
    expect(sub.codec, 'srt');
    expect(sub.externalPath, '/media/mix/Copper Valley (2018) 1080p.en.srt');
  });

  test('mixed_library_lists_movies_and_shows', () async {
    final b = await _build();
    final page = await b.source.browse(_root, const BrowseQuery());
    expect(page.items.map((i) => i.ref.kind).toSet(),
        {ItemKind.movie, ItemKind.show});
    expect(page.total, 3);
    final byTitle =
        await b.source.browse(_root, const BrowseQuery(sortId: 'title'));
    // `The Harbor Lights` sorts under H.
    expect(byTitle.items.map((i) => i.title),
        ['Copper Valley', 'Glass Orchard', 'The Harbor Lights']);
    final added =
        await b.source.browse(_root, const BrowseQuery(sortId: 'added'));
    expect(added.items.first.title, 'The Harbor Lights');
  });

  test('folders_library_only_when_something_is_unmatched', () async {
    final b = await _build();
    var libraries = await b.source.libraries();
    final folders =
        libraries.firstWhere((l) => l.ref.id == kFilesFoldersLibraryId);
    expect(folders.kind, LibraryKind.videos);
    expect(folders.title, 'Folders');

    final roots = await b.source.browse(_folders, const BrowseQuery());
    expect(roots.items.single.ref.kind, ItemKind.folder);
    final top = await b.source.children(roots.items.single.ref);
    expect(top.items.single.title, 'loose');
    final loose = await b.source.children(top.items.single.ref);
    expect(loose.items.single.ref.kind, ItemKind.video);
    expect(loose.items.single.title, 'home video');

    await b.fixture.index
        .removeFiles([fileKeyFor(FilesFixture.rootId, 'loose/home video.mkv')]);
    libraries = await b.source.libraries();
    expect(libraries.map((l) => l.ref.id), [FilesFixture.rootId]);
  });

  test('a_group_searched_with_no_winner_moves_to_folders', () async {
    final b = await _build();
    await b.fixture.match('harborlights|2020', null);
    final page = await b.source.browse(_root, const BrowseQuery());
    expect(
        page.items.map((i) => i.title), isNot(contains('The Harbor Lights')));
    final roots = await b.source.browse(_folders, const BrowseQuery());
    final top = await b.source.children(roots.items.single.ref);
    expect(top.items.map((i) => i.title), contains('Harbor Lights (2020)'));
  });

  test('specials_sort_last_and_next_up_skips_them', () async {
    final b = await _build();
    final f = b.fixture;
    final seasons = await b.source.children(f.ref(ItemKind.show, _show));
    expect(seasons.items.map((s) => s.index), [1, 0]);
    expect(seasons.items.map((s) => s.title), ['Season 1', 'Specials']);

    final eps = await b.source.children(seasons.items.first.ref);
    expect(eps.items.map((e) => e.title), ['Seedlings', 'Frost', 'Episode 3']);

    final show = f.ref(ItemKind.show, _show);
    expect((await b.source.nextUp(show))!.ref.externalId, '201-1-1');
    await f.index.setWatched('201-1-1', true);
    expect((await b.source.nextUp(show))!.ref.externalId, '201-1-2');
    await f.index.setWatched('201-1-3', true);
    // Nothing after the last watched episode is left; specials never count.
    expect(await b.source.nextUp(show), isNull);
  });

  test('watched_by_flag_or_ninety_percent', () async {
    final b = await _build();
    final f = b.fixture;
    Future<UserState> state(String id) async =>
        (await b.source.item(f.ref(ItemKind.movie, id))).summary.userState;

    await f.saveProgress(_movie, 95, 100);
    expect((await state(_movie)).watched, isTrue);
    await f.saveProgress(_movie, 50, 100);
    expect((await state(_movie)).watched, isFalse);
    expect((await state(_movie)).progressSeconds, 50);

    await b.source.setWatched(f.ref(ItemKind.movie, _movie), true);
    expect((await state(_movie)).watched, isTrue);
    expect(b.invalidated, containsAll(SourceRules.watchedChanged(f.sourceId)));

    await b.source.setWatched(f.ref(ItemKind.show, _show), true);
    final show = await b.source.item(f.ref(ItemKind.show, _show));
    expect(show.summary.userState.watched, isTrue);
    expect(show.summary.userState.unwatchedCount, 0);
  });

  test('finishing_a_multi_episode_file_finishes_each_episode', () async {
    final b = await _build();
    final f = b.fixture;
    const path = 'Glass Orchard/Glass Orchard S01E04-E05.mkv';
    await f.index.putFiles([
      IndexedFile(
        key: fileKeyFor(FilesFixture.rootId, path),
        rootId: FilesFixture.rootId,
        path: path,
        size: 10,
        modified: filesT0,
        firstSeen: filesT0,
        parsed: const ParsedName(
          path: path,
          isEpisode: true,
          title: 'Glass Orchard',
          groupKey: 'tv:glassorchard|',
          season: 1,
          episode: 4,
          episodeEnd: 5,
        ),
      ),
    ]);
    Future<bool> watched(String id) async =>
        (await b.source.item(f.ref(ItemKind.episode, id)))
            .summary
            .userState
            .watched;
    final show = f.ref(ItemKind.show, _show);
    await f.index.setWatched('201-1-3', true);
    expect((await b.source.nextUp(show))!.ref.externalId, '201-1-4');

    // Played as episode 4, to the end.
    await f.saveProgress('201-1-4', 95, 100);
    expect(await watched('201-1-4'), isTrue);
    expect(await watched('201-1-5'), isTrue);
    expect(await b.source.nextUp(show), isNull);

    // Unmarking either clears what the file recorded.
    await b.source.setWatched(f.ref(ItemKind.episode, '201-1-5'), false);
    expect(await watched('201-1-4'), isFalse);
    expect(await watched('201-1-5'), isFalse);
  });

  test('overlapping_multi_episode_files_link_no_episode_to_another', () async {
    final b = await _build();
    final f = b.fixture;
    IndexedFile file(String path, int first, int end) => IndexedFile(
          key: fileKeyFor(FilesFixture.rootId, path),
          rootId: FilesFixture.rootId,
          path: path,
          size: 10,
          modified: filesT0,
          firstSeen: filesT0,
          parsed: ParsedName(
            path: path,
            isEpisode: true,
            title: 'Glass Orchard',
            groupKey: 'tv:glassorchard|',
            season: 1,
            episode: first,
            episodeEnd: end,
          ),
        );
    await f.index.putFiles([
      file('Glass Orchard/Glass Orchard S01E04-E05.mkv', 4, 5),
      file('Glass Orchard/Glass Orchard S01E05-E06.mkv', 5, 6),
    ]);
    Future<UserState> state(String id) async =>
        (await b.source.item(f.ref(ItemKind.episode, id))).summary.userState;
    await f.saveProgress('201-1-4', 300, 1000);
    await f.saveProgress('201-1-6', 400, 1000);

    await b.source.setWatched(f.ref(ItemKind.episode, '201-1-5'), true);

    expect((await state('201-1-5')).watched, isTrue);
    for (final (id, at) in [('201-1-4', 300), ('201-1-6', 400)]) {
      final s = await state(id);
      expect(s.watched, isFalse, reason: id);
      expect(s.progressSeconds, at, reason: id);
    }
  });

  test('continue_watching_ignores_under_thirty_seconds', () async {
    final b = await _build();
    final f = b.fixture;
    await f.saveProgress(_movie, 20, 6000);
    await f.saveProgress('201-1-2', 600, 1800,
        at: filesT0.add(const Duration(hours: 1)));
    await f.saveProgress('102', 300, 6000,
        at: filesT0.add(const Duration(hours: 2)));
    final row = await b.source.continueWatching();
    expect(row.map((i) => i.ref.externalId), ['102', '201-1-2']);
    expect(row.last.showTitle, 'Glass Orchard');

    await b.source.removeFromContinueWatching(row.first.ref);
    expect((await b.source.continueWatching()).map((i) => i.ref.externalId),
        ['201-1-2']);
  });

  test('artwork_bucket_rounds_up_and_caps_at_original', () async {
    final b = await _build();
    const art = ArtworkRef('/copper.jpg');
    final r300 = await b.source.artwork(art, width: 300);
    expect(r300!.url, 'https://image.tmdb.org/t/p/w342/copper.jpg');
    expect(r300.headers, isEmpty);
    expect(r300.cacheKey, '${filesLocalSource.id}|/copper.jpg|w342');
    expect((await b.source.artwork(art, width: 92))!.url, contains('/w92/'));
    expect((await b.source.artwork(art, width: 781))!.url,
        'https://image.tmdb.org/t/p/original/copper.jpg');
  });

  test('provisional_groups_show_their_parsed_title_without_artwork', () async {
    final b = await _build();
    await b.fixture.addFiles(['Quiet Meridian (2011).mkv']);
    final page = await b.source.browse(_root, const BrowseQuery());
    final item = page.items.singleWhere((i) => i.title == 'Quiet Meridian');
    expect(item.ref.externalId, provisionalKey('quietmeridian|2011'));
    expect(item.year, 2011);
    expect(item.poster, isNull);
  });

  test('search_matches_identity_keys', () async {
    final b = await _build();
    final hits = await b.source.search('copper-val');
    expect(hits.map((i) => i.title), ['Copper Valley']);
    expect(await b.source.search('home vid'), hasLength(1));
  });

  test('unwatched_listing_drops_finished_titles', () async {
    final b = await _build();
    final f = b.fixture;
    await b.source.setWatched(f.ref(ItemKind.movie, _movie), true);
    final page = await b.source.unwatched();
    expect(
        page.items.map((i) => i.ref.externalId), containsAll(['102', _show]));
    expect(page.items.map((i) => i.ref.externalId), isNot(contains(_movie)));
  });

  test('set_match_pins_the_group_and_unmatch_moves_it_to_folders', () async {
    final b = await _build();
    final f = b.fixture;
    b.relay.down = false;
    await b.source.setMatch(f.ref(ItemKind.movie, '102'),
        const TmdbCandidate(id: 900, title: 'Pinned 900'));
    final g = f.index.group('harborlights|2020')!;
    expect((g.tmdbId, g.pinned), (900, true));
    expect((await b.source.item(f.ref(ItemKind.movie, '900'))).summary.title,
        'Pinned 900');

    await b.source.setMatch(f.ref(ItemKind.movie, '900'), null);
    expect(f.index.group('harborlights|2020')!.tmdbId, isNull);

    final unreadable = f.ref(
        ItemKind.video,
        unmatchedFileId(
            fileKeyFor(FilesFixture.rootId, 'loose/home video.mkv')));
    expect(() => b.source.setMatch(unreadable, null), throwsArgumentError);
  });

  test('a_movie_and_a_show_sharing_a_tmdb_number_are_matched_apart', () async {
    final b = await _build();
    final f = b.fixture;
    b.relay.down = false;
    // TMDB numbers movies and shows separately: show 101 is not movie 101.
    await f.match('tv:glassorchard|', 101, isShow: true);
    await f.index.putShow(const MatchedShow(tmdbId: 101, title: 'Orchard'));

    expect(b.source.canEditMatch(f.ref(ItemKind.show, _movie)), isTrue);
    await b.source.searchMatches(f.ref(ItemKind.show, _movie), 'Glass');
    expect(b.relay.searched, ['show:Glass']);

    await b.source.setMatch(f.ref(ItemKind.movie, _movie), null);
    expect(f.index.group('coppervalley|2018')!.tmdbId, isNull);
    final show = f.index.group('tv:glassorchard|')!;
    expect((show.tmdbId, show.isShow, show.pinned), (101, true, false));

    await b.source.setMatch(f.ref(ItemKind.show, _movie),
        const TmdbCandidate(id: 900, title: 'Pinned 900'));
    expect(f.index.group('tv:glassorchard|')!.tmdbId, 900);
    expect(f.index.group('coppervalley|2018')!.isShow, isFalse);
  });

  test('search_matches_asks_the_relay_by_kind', () async {
    final b = await _build();
    b.relay.down = false;
    await b.source.searchMatches(b.fixture.ref(ItemKind.show, _show), 'Glass');
    await b.source
        .searchMatches(b.fixture.ref(ItemKind.movie, _movie), 'Copper');
    expect(b.relay.searched, ['show:Glass', 'movie:Copper']);
  });

  test('unreachable_backend_still_browses', () async {
    final b = await _build(probeFailure: const BackendUnreachable('unplugged'));
    expect(b.source.connection, SourceConnectionStatus.connecting);
    await b.source.probe();
    expect(b.source.connection, SourceConnectionStatus.unreachable);
    expect(b.reauth, 0);
    final page = await b.source.browse(_root, const BrowseQuery());
    expect(page.items, hasLength(3));
    expect(
        (await b.source.item(b.fixture.ref(ItemKind.movie, _movie))).versions,
        hasLength(2));
  });

  test('unauthorized_flags_reauth', () async {
    for (final failure in const <BackendFailure>[
      BackendUnauthorized('401'),
      BackendPermissionLost('/media'),
    ]) {
      final b = await _build(probeFailure: failure);
      await b.source.probe();
      expect(b.reauth, 1, reason: '$failure');
      expect(b.source.connection, SourceConnectionStatus.unreachable);
    }
  });

  test('a_reachable_backend_is_local', () async {
    final b = await _build();
    await b.source.probe();
    expect(b.source.connection, SourceConnectionStatus.local);
  });
}
