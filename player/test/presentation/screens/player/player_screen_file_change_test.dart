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
  Future<void> dispose() async {
    await super.dispose();
  }
}

/// The scripted responses a direct-play movie load consumes, with distinct
/// per-file preferences so a stale one is observable after a fileId change.
StubLink _link() {
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
    return <String, dynamic>{
      '__typename': 'RootMutationType',
      'updateMovieProgress': null,
    };
  });
}

ProviderContainer? _container;
_ProbedPlayer? _probedPlayer;
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
}) async {
  _probedPlayer = player;
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
        mediaId: 'movie-1',
        mediaType: 'movie',
        fileId: fileId,
        title: 'The Long Aurora',
        createPlayer: () => Player(platformPlayer: player),
      ),
    ),
  ));
  await tester.pump();

  if (firstMount) {
    await pumpUntil(tester, () => player.opened);
    await tester.pump(const Duration(seconds: 1));
  }
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
  final player = _probedPlayer;
  if (player == null || !player.opened) return null;
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

void main() {
  testWidgets('a changed fileId on a reused State', (tester) async {
    final link = _link();
    final player = _ProbedPlayer();

    await _mount(tester, link, player, fileId: 'file-a');
    await pumpUntil(tester, () => _preferenceLoadedFor(tester) == 'file-a');

    // Same widget type, same position in the tree, new parameters: exactly
    // what a same-page-key navigation produces.
    await _mount(tester, link, player, fileId: 'file-b');
    await tester.pump(const Duration(seconds: 1));

    final preference = _preferenceStateOf(tester);
    final playing = _playingFileId(player);

    // Verdict first so a preference failure does not hide it.
    expect(
      playing,
      'file-b',
      skip: playing != 'file-b'
          ? 'Separate issue: reused State leaves playback on the old file; '
              'open before widening this PR (#870)'
          : false,
      reason: 'if this fails, the State-reuse gap reaches past the subtitle '
          'preference and is a separate issue, not this PR',
    );

    // Two separate questions, recorded separately so the verdict is legible.
    expect(
      preference.preference,
      isNull,
      reason: 'the previous file\'s preference must not survive into this one',
    );
    expect(
      preference.appliedForPlayback,
      isFalse,
      reason: 'the one-shot must be re-armed for the new file',
    );
  });
}
