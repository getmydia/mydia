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
// A published mpv track list, because the preference is applied off the back
// of the rebuild that follows `open()`, not the one the detail response
// produced: in direct play the file's own tracks arrive with mpv's probe, and
// it is mpv's list, not the server's, that was never folded into the streaming
// default server-side. A fixture whose derived list never changes after
// `open()` therefore never reaches the apply at all.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:media_kit/media_kit.dart';
import 'package:player/core/connection/connection_provider.dart' as conn;
import 'package:player/graphql/queries/media_segments.graphql.dart';
import 'package:player/graphql/queries/movie_detail.graphql.dart';
import 'package:player/graphql/queries/streaming_candidates.graphql.dart';
import 'package:player/graphql/queries/subtitle_content.graphql.dart';
import 'package:player/graphql/queries/subtitle_track_settings.graphql.dart';

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

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    state = state.copyWith(
      duration: const Duration(seconds: 90),
      position: Duration.zero,
      playing: false,
    );
    durationController.add(state.duration);
    positionController.add(state.position);
    playingController.add(false);
    // What mpv publishes as soon as it has probed the file.
    publishSubtitleTracks(const [_mpvSubtitleTrack]);
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

/// The scripted responses a direct-play movie load consumes, with
/// [preferredSubtitle] hung off its one media file.
StubLink _link({Map<String, dynamic>? preferredSubtitle}) {
  return StubLink((request, index) {
    if (_carries(request, documentNodeQuerySubtitleContent)) {
      return {
        '__typename': 'RootQueryType',
        'subtitleContent': 'WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nhello\n',
      };
    }
    if (_carries(request, documentNodeQueryMovieDetail)) {
      return movieDetailResponse(files: [
        mediaFileWithSubtitle(preferredSubtitle: preferredSubtitle),
      ]);
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
Future<void> _pump(
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
  await pumpUntil(
    tester,
    () => link.requests.any(
      (r) => _carries(r, documentNodeQueryStreamingCandidates),
    ),
  );
  // The track list is published after the candidates land, and
  // `_applySubtitlePreference` runs off the back of that.
  await pumpUntil(tester, () => _subtitleContentRequests(link) > 0);
  // Then let `_initializePlayer` finish. `_openPlayerAndStart` holds a 500ms
  // fake-time delay before its own detection pass, and a test that returns
  // while that is still pending fails Flutter's own pending-timer check --
  // which is a failure of the fixture, not of what is under test.
  await tester.pump(const Duration(seconds: 1));
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  testWidgets('a remembered track is fetched without the viewer picking',
      (tester) async {
    final link = _link(
      preferredSubtitle:
          preferredSubtitleObject(mode: 'TRACK', language: 'eng'),
    );

    await _pump(tester, link, _ProbedPlayer());

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

    await _pump(tester, link, player);

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

    await _pump(tester, link, player);
    expect(
      _subtitleContentRequests(link),
      1,
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
    // The fetch count above cannot see the bug on its own: the body is cached
    // per track id, so a second apply of the remembered track is not a second
    // request. This is the assertion that pins the flag.
    expect(
      player.selectedSubtitleTracks,
      hasLength(1),
      reason: 'the remembered track must reach the player exactly once, not '
          'once per track list revision',
    );
  });
}
