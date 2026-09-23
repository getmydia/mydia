// Regression coverage for `_applySubtitlePreference`.
//
// Asserts on the transport rather than on private state, the same way
// `player_screen_subtitle_offsets_cache_test.dart` does. Selecting a server
// subtitle track fetches its body through the `SubtitleContent` query, so
// that request reaching the link (or not) is an observable proxy for the
// selection having happened (or not), and it cannot pass for the wrong
// reason the way an assertion on a default-valued field could.
//
// Two pieces of the fixture are load-bearing rather than incidental.
//
// A `PlatformPlayer` fake, because the real `Player()` throws under
// `flutter test` for want of `MediaKit.ensureInitialized`, which leaves
// `_player` null -- and `_applySubtitleSelection` bails out on a null player,
// so without one the fetch under test can never happen however correct the
// preference logic is.
//
// A published mpv track list, because in direct play it is mpv's own list, not
// the server's, that was never folded into the streaming default server-side:
// the preference is what has to reconcile the two.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:media_kit/media_kit.dart';
import 'package:player/core/connection/connection_provider.dart' as conn;
import 'package:player/graphql/queries/media_segments.graphql.dart';
import 'package:player/graphql/queries/movie_detail.graphql.dart';
import 'package:player/graphql/queries/streaming_candidates.graphql.dart';
import 'package:player/graphql/queries/subtitle_content.graphql.dart';
import 'package:player/graphql/queries/subtitle_preference.graphql.dart';
import 'package:player/graphql/queries/subtitle_track_settings.graphql.dart';
import 'package:player/presentation/screens/player/player_screen.dart';
import 'package:player/presentation/widgets/toast/toaster.dart';

import '../../../test_utils/probed_tracks.dart';
import '../../../test_utils/stub_graphql_client.dart';
import 'player_screen_test_harness.dart';

/// Whether [request] carries the document [node].
///
/// By document, not by `operationName`: `QueryOptions` never sets the name, so
/// `request.operation.operationName` is null for everything this screen
/// issues. The generated document nodes are const, so this is an identity
/// comparison against the very node the query was built from -- a stronger
/// check than matching the printed query text, and the one
/// `player_screen_subtitle_offsets_cache_test.dart` already relies on.
///
/// The node parameter is typed `Object` because `graphql_flutter` does not
/// re-export the `gql` AST types, so `DocumentNode` cannot be named here.
bool _carries(Request request, Object node) =>
    request.operation.document == node;

/// How many times the screen asked the server for a subtitle body.
int _subtitleContentRequests(StubLink link) => link.requests
    .where((r) => _carries(r, documentNodeQuerySubtitleContent))
    .length;

/// The subtitle track mpv reports once it has probed the container.
///
/// Deliberately a language the stored preference does not name, so the fixture
/// cannot be satisfied by the preference matching mpv's own track instead of
/// the server's deliverable one -- which is the track a remembered choice
/// names, since only that one survives to the next episode.
const _mpvSubtitleTrack = SubtitleTrack('1', 'Japanese', 'jpn');

/// A media_kit player with no decoder behind it, carrying mpv's own track
/// list and recording what it was asked to show.
///
/// Modelled on `player_screen_source_switch_test.dart`'s `_Decoder`, which
/// replaces only what a widget test cannot provide: mpv/FFI, and the native
/// video output. Everything else is media_kit's real `Player`.
class _ProbedPlayer extends PlatformPlayer {
  _ProbedPlayer() : super(configuration: const PlayerConfiguration());

  /// VideoController waits on a native output this test never renders.
  /// Leaving the handle unresolved keeps texture/FFI calls out of the test.
  final _handle = Completer<int>();

  @override
  Future<int> get handle => _handle.future;

  /// Every subtitle track the screen handed to the player, in order.
  ///
  /// A second apply of the *same* track cannot be seen in
  /// `_subtitleContentRequests`: `_mediaKitSubtitleTrackMap` caches the body
  /// per track id, so the second fetch is a cache hit rather than a request.
  /// This is what a test that needs to see whether the preference applied
  /// again has to read.
  final selectedSubtitleTracks = <SubtitleTrack>[];

  /// Whether the screen has opened a source on this player yet, so a test can
  /// wait for the load to reach the point its own detection pass follows.
  bool opened = false;

  /// When set, [setSubtitleTrack] records its track and then waits for this,
  /// so a test can land a track-list revision *while* a selection is still in
  /// flight. That window is what `_preferenceAppliedForPlayback`'s placement
  /// before the await exists for.
  Completer<void>? holdSubtitleTrack;

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    opened = true;
    state = state.copyWith(
      duration: const Duration(seconds: 90),
      position: Duration.zero,
      playing: false,
    );
    durationController.add(state.duration);
    positionController.add(state.position);
    playingController.add(false);
    // What mpv publishes as soon as it has probed the file: a real
    // video/audio track too, not just the subtitle one, or `awaitRealTracks`
    // (see `tracks_ready.dart`) never sees a real track and every open waits
    // out its full timeout.
    state = state.copyWith(
      tracks: probedTracks(subtitle: const [_mpvSubtitleTrack]),
    );
    tracksController.add(state.tracks);
  }

  /// Stands in for media_kit revising the track list, which it does several
  /// times per playback as mpv's probe progresses.
  void publishSubtitleTracks(List<SubtitleTrack> tracks) {
    state = state.copyWith(tracks: Tracks(subtitle: tracks));
    tracksController.add(state.tracks);
  }

  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) async {
    selectedSubtitleTracks.add(track);
    await holdSubtitleTrack?.future;
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
  Future<void> dispose() async {
    await super.dispose();
  }
}

/// A player whose `open` publishes an empty track list first, as mpv does
/// before its probe has read the container, and publishes the probed list
/// only on [probe].
///
/// That empty revision is the window this file's startup tests are about:
/// with nothing from mpv yet, `resolveSubtitleTracks` falls back to the
/// server's list, and a preference applied then fetches from the server a
/// track mpv is about to show on its own.
class _SlowProbePlayer extends _ProbedPlayer {
  _SlowProbePlayer({required this.mpvSubtitles});

  final List<SubtitleTrack> mpvSubtitles;

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    opened = true;
    state = state.copyWith(
      duration: const Duration(seconds: 90),
      position: Duration.zero,
      playing: false,
    );
    durationController.add(state.duration);
    positionController.add(state.position);
    playingController.add(false);
    state = state.copyWith(tracks: const Tracks());
    tracksController.add(state.tracks);
  }

  void probe() {
    state = state.copyWith(tracks: probedTracks(subtitle: mpvSubtitles));
    tracksController.add(state.tracks);
  }
}

/// The server's view of a file whose English subtitle is an embedded
/// stream, which is the case the startup fetch used to hit.
Map<String, dynamic> _embeddedEnglishFile() => mediaFileWithSubtitle(
      trackId: '3',
      language: 'eng',
      title: 'English',
      url: null,
      embedded: true,
    );

/// Mounts the screen without waiting for the open to settle, so a test can
/// act between `open()` and mpv's probe.
Future<void> _mount(
  WidgetTester tester,
  StubLink link,
  _ProbedPlayer player,
) async {
  final container = buildPlayerScreenContainer(
    link: link,
    connectionState: conn.ConnectionState.p2p(serverNodeAddr: 'node-addr'),
    castManager: CapturingCastSessionManager(),
    proxyService: TrackingLocalProxyService(),
  );
  addTearDown(container.dispose);
  await pumpPlayerScreen(
    tester,
    container,
    createPlayer: () => Player(platformPlayer: player),
  );
  await pumpUntil(tester, () => player.opened);
}

/// A [StubLink] whose next subtitle-body fetch can be held open, so a test can
/// land a track-list revision inside that window.
///
/// The window is what the revision cases below need: mpv publishes its probe
/// results while the preference's own body fetch is still resolving, and
/// embedded extraction can take seconds, so a revision lands mid-apply rather
/// than before or after it. A gate makes that interleaving deterministic
/// instead of a matter of microtask scheduling.
class _GateableStubLink extends StubLink {
  _GateableStubLink(super.handler);

  /// Holds the next `SubtitleContent` request open until completed, then
  /// clears itself: only the first body fetch is gated.
  Completer<void>? holdSubtitleContent;

  /// Whether a held body fetch has been taken and is waiting.
  bool subtitleContentHeld = false;

  @override
  Stream<Response> request(Request request, [NextLink? forward]) async* {
    final hold = holdSubtitleContent;
    if (hold != null && _carries(request, documentNodeQuerySubtitleContent)) {
      holdSubtitleContent = null;
      subtitleContentHeld = true;
      await hold.future;
    }
    yield* super.request(request, forward);
  }
}

/// The scripted responses a direct-play movie load consumes, with
/// [preferredSubtitle] answered by the standalone preference query rather than
/// by the detail response.
_GateableStubLink _link({
  Map<String, dynamic>? preferredSubtitle,
  Map<String, dynamic>? file,
}) {
  return _GateableStubLink((request, index) {
    if (_carries(request, documentNodeQuerySubtitleContent)) {
      return {
        '__typename': 'RootQueryType',
        'subtitleContent': 'WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nhello\n',
      };
    }
    if (_carries(request, documentNodeQueryMovieDetail)) {
      return movieDetailResponse(files: [file ?? mediaFileWithSubtitle()]);
    }
    if (_carries(request, documentNodeQueryMovieSubtitlePreference)) {
      return subtitlePreferenceResponse(
        root: 'movie',
        id: 'movie-1',
        preferences: {'file-1': preferredSubtitle},
      );
    }
    if (_carries(request, documentNodeQueryMovieSegments)) {
      return movieSegmentsResponse();
    }
    if (_carries(request, documentNodeQuerySubtitleTrackSettings)) {
      return subtitleTrackSettingsResponse();
    }
    if (_carries(request, documentNodeQueryStreamingCandidates)) {
      return streamingCandidatesResponse(duration: 5400, directPlay: true);
    }
    if (request.variables.containsKey('strategy')) {
      return startStreamingSessionResponse(sessionId: 'sess-$index');
    }
    if (request.variables.containsKey('sessionId')) {
      return endStreamingSessionResponse();
    }
    return <String, dynamic>{
      '__typename': 'RootMutationType',
      'updateMovieProgress': null,
    };
  });
}

/// Mounts the screen against [link] and waits for the load to settle.
///
/// "Settled" is an identified point, not a timeout: the player has been opened
/// and the 500ms of fake time `_openPlayerAndStart` holds between `open()` and
/// its own detection pass has elapsed, which is the last thing the load does.
///
/// [settled] then waits for whatever this test expects the preference to have
/// produced -- a body fetch, or a selection on the player. It is how the
/// absence assertions in the Off and no-preference cases stay off a timeout:
/// the Off case waits for the selection that *should* be there, and the
/// no-preference case has no positive effect to wait for at all, so it asserts
/// on the state at that identified point instead.
Future<void> _pump(
  WidgetTester tester,
  StubLink link,
  _ProbedPlayer player, {
  bool Function()? settled,
}) async {
  final container = buildPlayerScreenContainer(
    link: link,
    connectionState: conn.ConnectionState.p2p(serverNodeAddr: 'node-addr'),
    castManager: CapturingCastSessionManager(),
    proxyService: TrackingLocalProxyService(),
  );
  addTearDown(container.dispose);

  await pumpPlayerScreen(
    tester,
    container,
    createPlayer: () => Player(platformPlayer: player),
  );
  await pumpUntil(tester, () => player.opened);
  // Past `_openPlayerAndStart`'s own 500ms wait, so its detection pass has run.
  // A test that returns while that timer is still pending fails Flutter's own
  // pending-timer check, which would be a failure of the fixture rather than of
  // what is under test.
  await tester.pump(const Duration(seconds: 1));

  if (settled != null) await pumpUntil(tester, settled);
}

/// How many times the mounted screen has retaken its one-shot preference
/// apply after a revision superseded it.
///
/// An `@visibleForTesting` getter on `_PlayerScreenState` is the only way to
/// observe this across libraries: a bare `_field` dynamic access cannot reach
/// library-private members in Dart. It is what separates an apply that
/// delivered from one that had to be sent again, which the transport alone
/// cannot show -- a retried apply of an already-fetched track is a cache hit
/// and not a second `SubtitleContent` request.
int _applyRetries(WidgetTester tester) {
  final state = tester.state(find.byType(PlayerScreen)) as dynamic;
  return state.preferenceApplyRetriesForTesting as int;
}

void main() {
  testWidgets('a remembered track is fetched without the viewer picking',
      (tester) async {
    final link = _link(
      preferredSubtitle:
          preferredSubtitleObject(mode: 'TRACK', language: 'eng'),
    );

    await _pump(
      tester,
      link,
      _ProbedPlayer(),
      settled: () => _subtitleContentRequests(link) > 0,
    );

    expect(
      _subtitleContentRequests(link),
      1,
      reason: 'the remembered English track should have been selected, which '
          'fetches its body exactly once',
    );
  });

  testWidgets('a remembered Off leaves every track alone', (tester) async {
    final player = _ProbedPlayer();
    final link = _link(preferredSubtitle: preferredSubtitleObject(mode: 'OFF'));

    await _pump(
      tester,
      link,
      player,
      settled: () => player.selectedSubtitleTracks.isNotEmpty,
    );

    expect(
      _subtitleContentRequests(link),
      0,
      reason: 'an explicit Off must not select anything, including the track '
          'the file would otherwise default to',
    );
    // The point of the assertion above is that Off selects nothing. The point
    // of this one is that it is still a *selection*: mpv switches on whichever
    // track the container flagged default, so an Off that never reached the
    // player would leave that track showing.
    expect(
      player.selectedSubtitleTracks,
      [SubtitleTrack.no()],
      reason: 'Off must reach the player as an explicit selection, not as a '
          'no-op that leaves mpv on its own default track',
    );
  });

  testWidgets('no preference leaves every track alone', (tester) async {
    final player = _ProbedPlayer();
    final link = _link();

    await _pump(tester, link, player);

    expect(_subtitleContentRequests(link), 0);
    expect(
      player.selectedSubtitleTracks,
      isEmpty,
      reason: 'with no stored preference nothing at all should have been '
          'selected',
    );
  });

  testWidgets('a republished track list does not fetch a second time',
      (tester) async {
    final player = _ProbedPlayer();
    final link = _link(
      preferredSubtitle:
          preferredSubtitleObject(mode: 'TRACK', language: 'eng'),
    );

    await _pump(
      tester,
      link,
      player,
      settled: () => _subtitleContentRequests(link) > 0,
    );
    expect(
      player.selectedSubtitleTracks,
      hasLength(1),
      reason: 'the preference has to have applied once for the revision below '
          'to be able to apply it a second time',
    );

    // media_kit revises its track list more than once per playback, and every
    // revision reaches `_applySubtitleTracks`. Pumping well past the first
    // apply, with a revision that genuinely changes the derived list, is what
    // would catch a missing `_preferenceAppliedForPlayback`.
    player.publishSubtitleTracks(const [
      _mpvSubtitleTrack,
      SubtitleTrack('2', 'Japanese (Signs)', 'jpn'),
    ]);
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 2));

    expect(
      _subtitleContentRequests(link),
      1,
      reason: 'the preference must apply once per file, not once per track '
          'list revision',
    );
    // Do not simplify this into the fetch count above. The fetched body is
    // cached per track id, so a second apply of the remembered track is a
    // cache hit and not a second request: with `_preferenceAppliedForPlayback`
    // removed, the assertion above still passes and only this one fails.
    expect(
      player.selectedSubtitleTracks,
      hasLength(1),
      reason: 'the remembered track must reach the player exactly once, not '
          'once per track list revision',
    );
  });

  testWidgets(
      'a track-list revision during the apply does not spend the preference',
      (tester) async {
    // The failure this pins: `_applySubtitlePreference` sets
    // `_preferenceAppliedForPlayback` before awaiting the apply, and a
    // revision landing during that await reaches `_syncSelectedSubtitleTrack`,
    // which bumps `_subtitleSelectionGeneration`. The bump makes
    // `shouldApplySubtitleSelection` discard the in-flight selection, so the
    // preference never reaches the player while the flag records that it did.
    // Embedded extraction can take 7-10s while mpv publishes probe results
    // early, so the window is wide.
    final link = _link(
      preferredSubtitle:
          preferredSubtitleObject(mode: 'TRACK', language: 'eng'),
    );
    final hold = Completer<void>();
    link.holdSubtitleContent = hold;
    final player = _ProbedPlayer();

    // The body fetch is held open, so the preferred track's apply is still
    // resolving when the revision below lands. That is the window a spent flag
    // turns into a lost preference.
    await _pump(
      tester,
      link,
      player,
      settled: () => link.subtitleContentHeld,
    );
    expect(
      player.selectedSubtitleTracks,
      isEmpty,
      reason: 'the hold is what keeps the apply in flight, so nothing can have '
          'reached the player yet',
    );

    // The revision that used to steal the one-shot. It changes the derived
    // list, which is what reaches `_syncSelectedSubtitleTrack` and bumps the
    // generation the held apply is running under.
    player.publishSubtitleTracks(const [
      _mpvSubtitleTrack,
      SubtitleTrack('2', 'Japanese (Signs)', 'jpn'),
    ]);
    await tester.pump();

    hold.complete();
    await pumpUntil(tester, () => player.selectedSubtitleTracks.isNotEmpty);

    expect(
      player.selectedSubtitleTracks.last.language,
      'eng',
      reason: 'the preference must be applied against the list that '
          'superseded the attempt, not lost with the spent flag',
    );
  });

  testWidgets(
      'a track list revised while a selection is still in flight applies it '
      'once', (tester) async {
    final hold = Completer<void>();
    final player = _ProbedPlayer()..holdSubtitleTrack = hold;
    final link = _link(preferredSubtitle: preferredSubtitleObject(mode: 'OFF'));

    await _pump(
      tester,
      link,
      player,
      settled: () => player.selectedSubtitleTracks.isNotEmpty,
    );
    expect(
      player.selectedSubtitleTracks,
      [SubtitleTrack.no()],
      reason: 'the Off has to have reached the player for the revision below '
          'to be able to select a second time',
    );

    // The window `_preferenceAppliedForPlayback` exists for: a revision
    // arriving while `_applySubtitleSelection` is still awaiting the player.
    // `_setSubtitleTrack` is the await in `_applySubtitlePreference` for an
    // Off, and it is held, so the selection is genuinely in flight here.
    player.publishSubtitleTracks(const [
      _mpvSubtitleTrack,
      SubtitleTrack('2', 'Japanese (Signs)', 'jpn'),
    ]);
    await tester.pump();
    hold.complete();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(
      player.selectedSubtitleTracks,
      [SubtitleTrack.no()],
      reason: 'the Off must be applied once, not once per revision landing '
          'while it is still in flight: the flag is set before that await '
          'precisely so this second apply never starts',
    );
  });

  testWidgets('revisions landing during an apply do not spend the retry budget',
      (tester) async {
    // Every revision below changes the derived track list, so every one of
    // them used to reach `_syncSelectedSubtitleTrack` and bump the generation
    // the held apply was running under. That apply is discarded on the way
    // back and the preference has to retake its one-shot, which it can only do
    // `_maxPreferenceApplyRetries` times -- against a list mpv keeps revising
    // for as long as a slow fetch (embedded extraction takes seconds) is open.
    final link = _link(
      preferredSubtitle:
          preferredSubtitleObject(mode: 'TRACK', language: 'eng'),
    );
    final hold = Completer<void>();
    link.holdSubtitleContent = hold;
    final player = _ProbedPlayer();

    await _pump(tester, link, player, settled: () => link.subtitleContentHeld);

    for (var revision = 0; revision < 4; revision++) {
      player.publishSubtitleTracks([
        _mpvSubtitleTrack,
        SubtitleTrack('${revision + 2}', 'Japanese (Signs $revision)', 'jpn'),
      ]);
      await tester.pump();
    }

    hold.complete();
    await pumpUntil(tester, () => player.selectedSubtitleTracks.isNotEmpty);
    await tester.pump(const Duration(seconds: 1));

    expect(_applyRetries(tester), 0,
        reason: 'a revision is not a supersession: the apply it landed under '
            'is still the live one, so there is nothing to retake');
    expect(player.selectedSubtitleTracks.last.language, 'eng',
        reason: 'and the preference is applied in place rather than retried '
            'into position');
  });

  testWidgets(
      'a selection a revision arrived alongside is reported as delivered, '
      'not discarded', (tester) async {
    // The distinction `_applySubtitlePreference`'s retry turns on: an apply
    // that delivered and had the revision adopt it versus one the revision
    // discarded. `_selectedSubtitleTrack` reads what the revision synced, not
    // the target, so a revision landing while the selection is still reaching
    // the player used to look like a discard -- and the retry sent the same
    // selection to the player a second time.
    final hold = Completer<void>();
    final player = _ProbedPlayer()..holdSubtitleTrack = hold;
    final link = _link(
      preferredSubtitle:
          preferredSubtitleObject(mode: 'TRACK', language: 'eng'),
    );

    await _pump(
      tester,
      link,
      player,
      settled: () => player.selectedSubtitleTracks.isNotEmpty,
    );

    // The revision lands inside the apply's own await on the player.
    player.publishSubtitleTracks(const [
      _mpvSubtitleTrack,
      SubtitleTrack('2', 'Japanese (Signs)', 'jpn'),
    ]);
    await tester.pump();
    hold.complete();
    player.holdSubtitleTrack = null;
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(_applyRetries(tester), 0,
        reason: 'the apply the revision landed under is the one that list was '
            'waiting for: nothing about it was discarded');
    expect(player.selectedSubtitleTracks, hasLength(1),
        reason: 'a revision that arrives as the selection is landing must not '
            'make that selection be sent to the player twice');
  });

  testWidgets(
      'in direct play the preference waits for mpv and selects its own track',
      (tester) async {
    final player = _SlowProbePlayer(
      mpvSubtitles: const [SubtitleTrack('1', 'English', 'eng')],
    );
    final link = _link(
      preferredSubtitle:
          preferredSubtitleObject(mode: 'TRACK', language: 'eng'),
      file: _embeddedEnglishFile(),
    );

    await _mount(tester, link, player);
    // The empty revision has landed and the server list is on screen as the
    // fallback. Give any apply it could trigger every chance to run.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(_subtitleContentRequests(link), 0,
        reason: 'nothing may be fetched against the fallback list while mpv '
            'is still probing');

    player.probe();
    await pumpUntil(tester, () => player.selectedSubtitleTracks.isNotEmpty);
    await tester.pump(const Duration(seconds: 1));

    expect(_subtitleContentRequests(link), 0,
        reason: 'mpv carries the stream itself, so the server must not be '
            'asked to extract it');
    expect(player.selectedSubtitleTracks.single.id, '1',
        reason: "the preference lands on mpv's own English track");
  });

  testWidgets(
      'if mpv never reports tracks, the preference fetches from the server',
      (tester) async {
    final player = _SlowProbePlayer(mpvSubtitles: const []);
    final link = _link(
      preferredSubtitle:
          preferredSubtitleObject(mode: 'TRACK', language: 'eng'),
      file: _embeddedEnglishFile(),
    );

    await _mount(tester, link, player);
    // Past `awaitRealTracks`' 3 s cap in `_openPlayerAndStart`.
    await tester.pump(const Duration(seconds: 4));
    await pumpUntil(tester, () => _subtitleContentRequests(link) > 0);

    expect(_subtitleContentRequests(link), 1,
        reason: "with no mpv list the server's copy is the only one there is");
  });

  testWidgets('selecting a track mpv already carries shows no loading toast',
      (tester) async {
    final player = _SlowProbePlayer(
      mpvSubtitles: const [SubtitleTrack('1', 'English', 'eng')],
    );
    final link = _link(
      preferredSubtitle:
          preferredSubtitleObject(mode: 'TRACK', language: 'eng'),
      file: _embeddedEnglishFile(),
    );

    await _mount(tester, link, player);

    // Every message the toast layer is asked to show, however briefly. A
    // toast shown and closed within one frame never paints, so asserting on
    // `find.text` alone could pass while the code still shows it.
    final controller = Toaster.maybeControllerOf(
      tester.element(find.byType(PlayerScreen)),
    )!;
    final shown = <String>[];
    void record() {
      final message = controller.current?.message;
      if (message != null) shown.add(message);
    }

    controller.addListener(record);
    addTearDown(() => controller.removeListener(record));

    player.probe();
    await pumpUntil(tester, () => player.selectedSubtitleTracks.isNotEmpty);
    await tester.pump(const Duration(seconds: 1));

    expect(shown, isNot(contains('Loading subtitle...')));
  });
}
