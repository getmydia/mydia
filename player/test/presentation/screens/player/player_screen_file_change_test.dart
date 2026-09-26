// Does a PlayerScreen whose fileId changes under a reused State notice?
//
// go_router 18.0.1 keys a plain GoRoute's page off the route pattern
// (match.dart:231), so /player/episode/A and /player/episode/B share a page
// key, the Navigator updates the route in place, and this State survives the
// navigation. These tests pump that shape directly rather than driving
// go_router, so they assert the State's own behaviour with nothing else in
// the way.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:media_kit/media_kit.dart';
import 'package:player/core/connection/connection_provider.dart' as conn;
import 'package:player/graphql/mutations/update_movie_progress.graphql.dart';
import 'package:player/graphql/queries/media_segments.graphql.dart';
import 'package:player/graphql/queries/movie_detail.graphql.dart';
import 'package:player/graphql/queries/streaming_candidates.graphql.dart';
import 'package:player/graphql/queries/subtitle_content.graphql.dart';
import 'package:player/graphql/queries/subtitle_preference.graphql.dart';
import 'package:player/graphql/queries/subtitle_track_settings.graphql.dart';
import 'package:player/presentation/screens/player/player_screen.dart';
import 'package:player/presentation/screens/player/subtitle_preference.dart';

import '../../../test_utils/probed_tracks.dart';
import '../../../test_utils/stub_graphql_client.dart';
import '../../../test_utils/toast_harness.dart';
import 'player_screen_test_harness.dart';

/// The server's own subtitle track on the one media file below.
const _trackTitle = 'English (Signs & Songs)';

/// The mpv-native track the fake player publishes.
const _mpvSubtitleTrack = SubtitleTrack('1', 'Japanese', 'jpn');

/// Whether [request] carries the document [node].
bool _carries(Request request, Object node) =>
    request.operation.document == node;

/// A media_kit player with no decoder behind it, carrying mpv's own track
/// list and recording what it was asked to show.
class _ProbedPlayer extends PlatformPlayer {
  _ProbedPlayer() : super(configuration: const PlayerConfiguration());

  final _handle = Completer<int>();

  @override
  Future<int> get handle => _handle.future;

  final selectedSubtitleTracks = <SubtitleTrack>[];

  bool opened = false;

  /// Every source URI the screen opened on this player, in order.
  final openedUris = <String>[];

  bool disposed = false;

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    opened = true;
    if (playable is Media) {
      openedUris.add(playable.uri);
    }
    state = state.copyWith(
      duration: const Duration(seconds: 90),
      position: Duration.zero,
      playing: false,
    );
    durationController.add(state.duration);
    positionController.add(state.position);
    playingController.add(false);
    // `probedTracks` adds the video/audio tracks `awaitRealTracks` (see
    // `tracks_ready.dart`) actually looks at; a subtitle-only `Tracks` never
    // reads as probed and burns the full timeout on every open.
    state = state.copyWith(tracks: probedTracks(subtitle: [_mpvSubtitleTrack]));
    tracksController.add(state.tracks);
  }

  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) async {
    selectedSubtitleTracks.add(track);
  }

  @override
  Future<void> play() async {
    state = state.copyWith(playing: true);
    playingController.add(true);
  }

  @override
  Future<void> pause() async {
    state = state.copyWith(playing: false);
    playingController.add(false);
  }

  @override
  Future<void> seek(Duration position) async {
    state = state.copyWith(position: position);
    positionController.add(position);
  }

  @override
  // ignore: must_call_super
  Future<void> dispose() async {
    disposed = true;
    // Deliberately does not call `super.dispose()`: the base implementation
    // closes every controller on this instance, including
    // `positionController`, and `_mount` reuses the same `_ProbedPlayer`
    // across a switch so a test can seek and read back across it. A closed
    // controller makes the *second* `open()` throw
    // ("Cannot add new events after calling close"), which every real
    // platform player avoids simply by being a fresh instance per load (see
    // `_openPlayerAndStart`'s `widget.createPlayer?.call() ?? Player()`).
    // `disposed` is what every test here actually asserts on.
  }
}

/// The scripted responses a direct-play movie load consumes, with distinct
/// per-file preferences so a stale one is observable after a fileId change.
///
/// [onPreference], when it returns non-null, answers the subtitle-preference
/// query in its place; used by tests that need to shape that one response
/// differently from the shared default.
///
/// [onMovieProgress], when it returns non-null, answers `UpdateMovieProgress`
/// in its place -- used to hold one movie id's save back on a `Completer` so
/// a test can park a switch inside it. Answers any movie/file id already:
/// none of the branches below key off the requested id (streaming candidates
/// keys off the file id in the request instead of the fixed movie id these
/// fixtures carry).
StubLink _link({
  Object? Function(Request request)? onPreference,
  Object? Function(Request request)? onMovieProgress,
}) {
  return StubLink((request, index) {
    if (_carries(request, documentNodeQuerySubtitleContent)) {
      return {
        '__typename': 'RootQueryType',
        'subtitleContent': 'WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nhi\n',
      };
    }
    if (_carries(request, documentNodeQueryMovieDetail)) {
      return movieDetailResponse(files: [
        mediaFileWithSubtitle(fileId: 'file-a'),
        mediaFileWithSubtitle(fileId: 'file-b'),
      ]);
    }
    if (_carries(request, documentNodeQueryMovieSubtitlePreference)) {
      final hooked = onPreference?.call(request);
      if (hooked != null) return hooked;
      return subtitlePreferenceResponse(
        root: 'movie',
        id: 'movie-1',
        preferences: {
          'file-a': preferredSubtitleObject(
            mode: 'TRACK',
            language: 'eng',
            trackTitle: _trackTitle,
          ),
          'file-b': preferredSubtitleObject(mode: 'TRACK', language: 'jpn'),
        },
      );
    }
    if (_carries(request, documentNodeQueryMovieSegments)) {
      return movieSegmentsResponse();
    }
    if (_carries(request, documentNodeQuerySubtitleTrackSettings)) {
      return subtitleTrackSettingsResponse();
    }
    if (_carries(request, documentNodeQueryStreamingCandidates)) {
      final id = request.variables['id'] as String? ?? 'file-1';
      return streamingCandidatesResponse(
        duration: 5400,
        directPlay: true,
        fileId: id,
      );
    }
    if (_carries(request, documentNodeMutationUpdateMovieProgress)) {
      final hooked = onMovieProgress?.call(request);
      if (hooked != null) return hooked;
    }
    // The fallback already answers UpdateMovieProgress; tests read those
    // requests back from `link.requests`.
    return <String, dynamic>{
      '__typename': 'RootMutationType',
      'updateMovieProgress': null,
    };
  });
}

ProviderContainer? _container;
var _containerTearDownRegistered = false;

/// Mounts or updates the screen against [link] on [player].
///
/// The first call builds the provider tree. Later calls with a different
/// [fileId] re-pump the same slot, reusing the State the way a same-page-key
/// navigation does.
Future<void> _mount(
  WidgetTester tester,
  StubLink link,
  _ProbedPlayer player, {
  required String fileId,
  String mediaId = 'movie-1',
  bool waitForOpen = true,
}) async {
  final firstMount = _container == null;
  _container ??= buildPlayerScreenContainer(
    link: link,
    connectionState: conn.ConnectionState.p2p(serverNodeAddr: 'node-addr'),
    castManager: CapturingCastSessionManager(),
    proxyService: TrackingLocalProxyService(),
  );
  if (!_containerTearDownRegistered) {
    addTearDown(_container!.dispose);
    _containerTearDownRegistered = true;
  }

  await tester.pumpWidget(UncontrolledProviderScope(
    container: _container!,
    child: MaterialApp(
      builder: toastLayerBuilder,
      home: PlayerScreen(
        mediaId: mediaId,
        mediaType: 'movie',
        fileId: fileId,
        title: 'The Long Aurora',
        createPlayer: () => Player(platformPlayer: player),
      ),
    ),
  ));
  await tester.pump();

  if (firstMount && waitForOpen) {
    await pumpUntil(tester, () => player.opened);
    await tester.pump(const Duration(seconds: 1));
  }
}

/// Like [_mount], but builds a fresh platform player from [next] for every
/// `createPlayer` call, so a test can tell one file's player from the next.
Future<void> _mountWithFactory(
  WidgetTester tester,
  StubLink link,
  _ProbedPlayer Function() next, {
  required String fileId,
}) async {
  _container ??= buildPlayerScreenContainer(
    link: link,
    connectionState: conn.ConnectionState.p2p(serverNodeAddr: 'node-addr'),
    castManager: CapturingCastSessionManager(),
    proxyService: TrackingLocalProxyService(),
  );
  if (!_containerTearDownRegistered) {
    addTearDown(_container!.dispose);
    _containerTearDownRegistered = true;
  }
  await tester.pumpWidget(UncontrolledProviderScope(
    container: _container!,
    child: MaterialApp(
      builder: toastLayerBuilder,
      home: PlayerScreen(
        mediaId: 'movie-1',
        mediaType: 'movie',
        fileId: fileId,
        title: 'The Long Aurora',
        createPlayer: () => Player(platformPlayer: next()),
      ),
    ),
  ));
  await tester.pump(const Duration(seconds: 1));
}

/// Reads the subtitle-preference fields through the mounted State.
///
/// `@visibleForTesting` getters on `_PlayerScreenState` are the only way to
/// observe these across libraries; the brief's bare `_field` dynamic access
/// cannot reach library-private members in Dart.
({SubtitlePreference? preference, bool appliedForPlayback}) _preferenceStateOf(
    WidgetTester tester) {
  final state = tester.state(find.byType(PlayerScreen));
  final binding = state as dynamic;
  return (
    preference: binding.subtitlePreferenceForTesting as SubtitlePreference?,
    appliedForPlayback: binding.preferenceAppliedForTesting as bool,
  );
}

/// Which file's preference load has finished, or null while still loading.
String? _preferenceLoadedFor(WidgetTester tester) {
  final finder = find.byType(PlayerScreen);
  if (finder.evaluate().isEmpty) return null;
  if (find.byType(CircularProgressIndicator).evaluate().isNotEmpty) {
    return null;
  }
  return tester.widget<PlayerScreen>(finder).fileId;
}

/// The file id in the last source the screen opened on [player].
String? _playingFileId(_ProbedPlayer player) {
  if (player.openedUris.isEmpty) return null;
  final uri = player.openedUris.last;
  return RegExp(r'/direct/([^/]+)/stream').firstMatch(uri)?.group(1);
}

/// Waits for whatever a file switch on a reused State is doing, the way
/// [pumpUntilReal] does.
///
/// A switch re-runs the same real asynchronous I/O the first load does (see
/// `player_screen_test_harness.dart`'s `pumpUntilReal` doc comment), so
/// plain `pumpUntil` -- fake-clock pumps with no real event-loop turn --
/// can leave [condition] stuck forever even though the switch itself is not
/// stuck at all.
Future<void> _pumpUntilSwitched(
  WidgetTester tester,
  bool Function() condition,
) =>
    tester.runAsync(() => pumpUntilReal(tester, condition));

void main() {
  setUp(() {
    _container = null;
    _containerTearDownRegistered = false;
  });

  testWidgets('a changed fileId on a reused State', (tester) async {
    final link = _link();
    final player = _ProbedPlayer();

    await _mount(tester, link, player, fileId: 'file-a');
    await pumpUntil(tester, () => _preferenceLoadedFor(tester) == 'file-a');

    // Same widget type, same position in the tree, new parameters: exactly
    // what a same-page-key navigation produces.
    await _mount(tester, link, player, fileId: 'file-b');
    await _pumpUntilSwitched(tester, () => _playingFileId(player) == 'file-b');

    final preference = _preferenceStateOf(tester);
    final playing = _playingFileId(player);

    // Verdict first so a preference failure does not hide it.
    expect(
      playing,
      'file-b',
      reason: 'a reused State must load the new file',
    );

    // file-b carries its own preference in `_link()`'s fixture (Japanese, no
    // track title) -- distinct from file-a's (English, with one) -- so this
    // fails if the old file's preference leaked, not merely if none loaded.
    final loaded = preference.preference;
    expect(loaded, isA<PreferTrack>(),
        reason: 'file-b must load its own preference');
    expect(
      (loaded as PreferTrack?)?.language,
      'jpn',
      reason: 'the previous file\'s preference must not survive into this one',
    );
    expect(
      preference.appliedForPlayback,
      isTrue,
      reason: 'the one-shot must be re-armed and applied for the new file',
    );
  });

  testWidgets('the old player is disposed when the file changes',
      (tester) async {
    final link = _link();
    final players = <_ProbedPlayer>[];
    // A fresh platform player per `createPlayer` call, so the first file's
    // player can be told apart from the second's.
    _ProbedPlayer next() {
      final p = _ProbedPlayer();
      players.add(p);
      return p;
    }

    await _mountWithFactory(tester, link, next, fileId: 'file-a');
    await pumpUntil(tester, () => _preferenceLoadedFor(tester) == 'file-a');
    await _mountWithFactory(tester, link, next, fileId: 'file-b');
    await _pumpUntilSwitched(
        tester, () => players.length == 2 && players[1].opened);

    expect(players.first.disposed, isTrue,
        reason: 'the first file\'s player must be torn down');
    expect(players.last.disposed, isFalse);
    expect(_playingFileId(players.last), 'file-b');
  });

  testWidgets('progress for the old file is saved under the old id',
      (tester) async {
    final link = _link();
    final player = _ProbedPlayer();

    await _mount(tester, link, player, fileId: 'file-a', mediaId: 'movie-1');
    await pumpUntil(tester, () => _preferenceLoadedFor(tester) == 'file-a');
    await player.seek(const Duration(seconds: 30));
    await tester.pump();

    await _mount(tester, link, player, fileId: 'file-b', mediaId: 'movie-2');
    await _pumpUntilSwitched(tester, () => _playingFileId(player) == 'file-b');

    final saves = link.requests
        .where((r) => _carries(r, documentNodeMutationUpdateMovieProgress))
        .map((r) => r.variables)
        .toList();
    expect(
      saves.where(
          (v) => v['movieId'] == 'movie-1' && v['positionSeconds'] == 30),
      isNotEmpty,
      reason: 'the switch must save file A\'s position against movie-1',
    );
    expect(
      saves.where(
          (v) => v['movieId'] == 'movie-2' && v['positionSeconds'] == 30),
      isEmpty,
      reason: 'file A\'s position must never be written to movie-2',
    );
  });

  testWidgets('the watched flag is re-armed for the new file', (tester) async {
    final link = _link();
    final player = _ProbedPlayer();

    await _mount(tester, link, player, fileId: 'file-a');
    await pumpUntil(tester, () => _preferenceLoadedFor(tester) == 'file-a');
    // `isWatched` measures against the server-reported duration
    // (`streamingCandidatesResponse`'s 5400s, in the shared `_link()`), not
    // this fake player's own 90s `duration` field: `StreamTimeline.
    // resolveDuration` prefers the server's figure whenever it is known. 4900
    // of 5400s is past the 90% watched threshold.
    await player.seek(const Duration(seconds: 4900));
    await tester.pump();
    final state = tester.state(find.byType(PlayerScreen)) as dynamic;
    expect(state.watchedInvalidationSentForTesting as bool, isTrue,
        reason: 'sanity: file A must have crossed the watched threshold');

    await _mount(tester, link, player, fileId: 'file-b');
    await _pumpUntilSwitched(tester, () => _playingFileId(player) == 'file-b');

    expect(state.watchedInvalidationSentForTesting as bool, isFalse);
    expect(state.isDownloadedSourceForTesting as bool, isFalse);
  });

  testWidgets('a load for the old file cannot land after the switch',
      (tester) async {
    // movie-1's preference is held back, which parks file A's whole load:
    // `_fetchProgressAndEpisodes` is awaited before the player is opened.
    final held = Completer<Object>();
    final link = _link(onPreference: (request) {
      if (request.variables['id'] != 'movie-1') return null;
      return held.future;
    });
    final player = _ProbedPlayer();

    await _mount(tester, link, player,
        fileId: 'file-a', mediaId: 'movie-1', waitForOpen: false);
    await tester.pump(const Duration(milliseconds: 200));
    expect(player.openedUris, isEmpty, reason: 'sanity: file A is parked');

    await _mount(tester, link, player, fileId: 'file-b', mediaId: 'movie-2');
    await _pumpUntilSwitched(tester, () => _playingFileId(player) == 'file-b');

    // Release file A's parked load. Its answer carries a file-b entry with a
    // language no other response uses, so a stale write is observable.
    held.complete(subtitlePreferenceResponse(
      root: 'movie',
      id: 'movie-1',
      preferences: {
        'file-b': preferredSubtitleObject(mode: 'TRACK', language: 'fre'),
      },
    ));
    // A plain fake-clock pump cannot resume the parked run: releasing the
    // completer only schedules a microtask, and reaching the rest of the
    // load past it depends on real asynchronous I/O the same way the second
    // `_initializePlayer` does (see `_pumpUntilSwitched`).
    await tester
        .runAsync(() => Future.delayed(const Duration(milliseconds: 300)));
    await tester.pump();

    expect(player.openedUris.where((u) => u.contains('/file-a/')), isEmpty,
        reason: 'the superseded load must not go on to open file A');
    expect(_playingFileId(player), 'file-b');
    expect(
      (_preferenceStateOf(tester).preference as PreferTrack?)?.language,
      isNot('fre'),
      reason: 'movie-1\'s late answer must not overwrite file B\'s',
    );
  });

  testWidgets(
      'a second switch while the first still awaits its save never credits '
      'the file in between', (tester) async {
    // Holds movie-1's own save back, so the movie-1 -> movie-2 switch parks
    // inside it -- the same shape as the "load cannot land" test above, but
    // for the save step instead of the load step.
    final held = Completer<Object>();
    final link = _link(onMovieProgress: (request) {
      if (request.variables['movieId'] != 'movie-1') return null;
      return held.future;
    });
    final player = _ProbedPlayer();

    await _mount(tester, link, player, fileId: 'file-a', mediaId: 'movie-1');
    await pumpUntil(tester, () => _preferenceLoadedFor(tester) == 'file-a');
    await player.seek(const Duration(seconds: 30));
    await tester.pump();

    // Switch A (movie-1 -> movie-2) starts and parks inside its own save for
    // movie-1 (held above). `_player` must already be detached by the time
    // this returns, or switch B below would read movie-1's still-live player
    // as movie-2's.
    await _mount(tester, link, player, fileId: 'file-b', mediaId: 'movie-2');

    // `ProgressService` throttles any sync attempt for 10 *real* seconds
    // after the last one it started, regardless of which id that one
    // targeted -- and switch A's parked save above already started one. Left
    // alone, switch B's own (would-be erroneous) save silently no-ops on
    // that throttle before it ever reaches `_player`, passing this test
    // whether or not the switch itself is correct. Waiting past it is what
    // makes the assertions below mean anything.
    await tester.runAsync(() => Future.delayed(const Duration(seconds: 11)));

    // Switch B (movie-2 -> movie-3) starts immediately, before A resumes.
    await _mount(tester, link, player, fileId: 'file-c', mediaId: 'movie-3');
    await _pumpUntilSwitched(tester, () => _playingFileId(player) == 'file-c');

    // Release A's held save and let its now-superseded tail drain.
    held.complete(<String, dynamic>{
      '__typename': 'RootMutationType',
      'updateMovieProgress': null,
    });
    await tester
        .runAsync(() => Future.delayed(const Duration(milliseconds: 300)));
    await tester.pump();

    final saves = link.requests
        .where((r) => _carries(r, documentNodeMutationUpdateMovieProgress))
        .map((r) => r.variables)
        .toList();
    expect(
      saves.where(
          (v) => v['movieId'] == 'movie-2' && v['positionSeconds'] == 30),
      isEmpty,
      reason: 'movie-1\'s position must never be written under movie-2, '
          'the file it was never actually playing',
    );
    expect(_playingFileId(player), 'file-c',
        reason: 'the most recent switch must win');
    expect(
      player.openedUris.where((u) => u.contains('/file-b/')),
      isEmpty,
      reason: 'a switch superseded before it reloads must never open the '
          'file it was replacing',
    );
  });

  testWidgets(
      'disposing mid-switch never saves the old file\'s position under the '
      'new id', (tester) async {
    // Same hold as above, but this time the screen goes away entirely while
    // parked, instead of a second switch arriving.
    final held = Completer<Object>();
    final link = _link(onMovieProgress: (request) {
      if (request.variables['movieId'] != 'movie-1') return null;
      return held.future;
    });
    final player = _ProbedPlayer();

    await _mount(tester, link, player, fileId: 'file-a', mediaId: 'movie-1');
    await pumpUntil(tester, () => _preferenceLoadedFor(tester) == 'file-a');
    // An odd value nothing else in this test produces, so a stale write is
    // unambiguous.
    await player.seek(const Duration(seconds: 37));
    await tester.pump();

    // The switch (movie-1 -> movie-2) starts and parks inside its own save
    // for movie-1 (held above).
    await _mount(tester, link, player, fileId: 'file-b', mediaId: 'movie-2');

    // See the matching comment in the overlapping-switches test above: the
    // parked save already started `ProgressService`'s 10-real-second
    // throttle, and without waiting it out, `dispose()`'s own save below
    // would no-op on the throttle rather than on `_player` being detached --
    // passing this test whether or not the fix is in place.
    await tester.runAsync(() => Future.delayed(const Duration(seconds: 11)));

    // The screen is torn down while the switch is still parked.
    await tester.pumpWidget(const SizedBox());

    // Release the held save and let the (now-orphaned) switch drain.
    held.complete(<String, dynamic>{
      '__typename': 'RootMutationType',
      'updateMovieProgress': null,
    });
    await tester
        .runAsync(() => Future.delayed(const Duration(milliseconds: 300)));
    await tester.pump();

    final saves = link.requests
        .where((r) => _carries(r, documentNodeMutationUpdateMovieProgress))
        .map((r) => r.variables)
        .toList();
    expect(
      saves.where(
          (v) => v['movieId'] == 'movie-2' && v['positionSeconds'] == 37),
      isEmpty,
      reason: 'dispose() must not find a live player to credit to movie-2, '
          'the file the switch never actually reached',
    );
  });
}
