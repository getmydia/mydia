// Regression coverage for `_rememberSubtitlePreference`.
//
// The write exists to remember a *viewer pick*, so both of the first two
// tests drive a real pick through one of the two public ways in: the
// remote-control intent the receiver dispatches (`RemoteTargetController` ->
// `selectTrack`), and a tap on the sheet's own track tile. Neither drives the
// preference that applies itself on load -- that is a stored choice being
// restored, not a new one. Rewriting the descriptor from it would let a
// single episode whose list lacks the remembered title degrade what is stored
// for the rest of the show, and it would issue a mutation for a viewer who
// did nothing.
//
// Assertions are on the transport, the same way
// `subtitle_preference_apply_test.dart` asserts on the `SubtitleContent`
// fetch: the `SetSubtitlePreference` request and its `variables` are what a
// later episode depends on, and they cannot pass for the wrong reason the way
// an assertion on a default-valued field could.
//
// The failure cases matter as much as the success one. The mutation is
// fire-and-forget on purpose: the track has already changed by the time it
// runs, so a rejection (or a server too old to know the mutation) must cost
// the preference and never the playback.
//
// Two pieces of the fixture are load-bearing rather than incidental.
//
// A `PlatformPlayer` fake, for the reason `subtitle_preference_apply_test.dart`
// gives: the real `Player()` throws under `flutter test` for want of
// `MediaKit.ensureInitialized`, which leaves `_player` null, and a selection
// with no player behind it never reaches the fetch or `setSubtitleTrack` that
// a pick has to get through before it can be remembered.
//
// A track that is the server's own (non-embedded, deliverable) rather than
// mpv's, so the pick names a track whose flags the server actually knows:
// that is what the written descriptor has to carry.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:media_kit/media_kit.dart';
import 'package:player/core/connection/connection_provider.dart' as conn;
import 'package:player/core/remote/remote_control_intent.dart';
import 'package:player/core/remote/remote_target_controller.dart';
import 'package:player/graphql/mutations/set_subtitle_preference.graphql.dart';
import 'package:player/graphql/queries/media_segments.graphql.dart';
import 'package:player/graphql/queries/movie_detail.graphql.dart';
import 'package:player/graphql/queries/streaming_candidates.graphql.dart';
import 'package:player/graphql/queries/subtitle_content.graphql.dart';
import 'package:player/graphql/queries/subtitle_preference.graphql.dart';
import 'package:player/graphql/queries/subtitle_track_settings.graphql.dart';
import 'package:player/presentation/widgets/subtitle_track_selector.dart';
import 'package:player/presentation/widgets/video_controls/panel_controls.dart';

import '../../../test_utils/stub_graphql_client.dart';
import 'player_screen_test_harness.dart';

/// The server's own subtitle track on the one media file below.
const _serverTrackId = '3';
const _trackTitle = 'English (Signs & Songs)';

/// The mpv-native track the fake player publishes, whose only identity is
/// what media_kit exposes: a title, a language, and an id of its own.
const _mpvSubtitleTrack = SubtitleTrack('1', 'Japanese', 'jpn');

/// Whether [request] carries the document [node].
///
/// By document, not by `operationName`: `QueryOptions`/`MutationOptions` never
/// set the name, so `request.operation.operationName` is null for everything
/// this screen issues. The generated document nodes are const, so this is an
/// identity comparison against the very node the request was built from -- a
/// stronger check than matching the printed query text, and the one
/// `player_screen_subtitle_offsets_cache_test.dart` already relies on.
///
/// The node parameter is typed `Object` because `graphql_flutter` does not
/// re-export the `gql` AST types, so `DocumentNode` cannot be named here.
bool _carries(Request request, Object node) =>
    request.operation.document == node;

/// Every `setSubtitlePreference` this screen has written back.
Iterable<Request> _writes(StubLink link) => link.requests
    .where((r) => _carries(r, documentNodeMutationSetSubtitlePreference));

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

  /// Every subtitle track the screen handed to the player, in order, so a
  /// test can wait for a pick to have landed -- which is the identified point
  /// an absence assertion about the write has to stand on.
  final selectedSubtitleTracks = <SubtitleTrack>[];

  /// Whether the screen has opened a source on this player yet, so a test can
  /// wait for the load to reach the point its own detection pass follows.
  bool opened = false;

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
    // What mpv publishes as soon as it has probed the file.
    state = state.copyWith(tracks: const Tracks(subtitle: [_mpvSubtitleTrack]));
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

/// A [StubLink] that holds each `setSubtitlePreference` for a scripted delay
/// before it answers.
///
/// A stubbed server that answers on receipt cannot reproduce the order this
/// fixture exists to test: what matters to the real upsert is when a write
/// *lands*, not when it was issued, and the unconditional upsert makes the
/// last one to land the one the show is pinned to. Holding the first write
/// past the second is what gives the landing order a chance to differ from
/// the issuing order, and so a chance to be wrong.
class _DelayedWriteLink extends StubLink {
  _DelayedWriteLink(super.handler, this.mutationDelays);

  /// How long the nth `setSubtitlePreference` is held before it answers. The
  /// last entry repeats; an empty list holds nothing.
  final List<Duration> mutationDelays;

  int _writesStarted = 0;

  @override
  Stream<Response> request(Request request, [NextLink? forward]) async* {
    if (mutationDelays.isNotEmpty &&
        _carries(request, documentNodeMutationSetSubtitlePreference)) {
      final started = _writesStarted++;
      final delay = mutationDelays[started < mutationDelays.length
          ? started
          : mutationDelays.length - 1];
      await Future<void>.delayed(delay);
    }
    yield* super.request(request, forward);
  }
}

/// The scripted responses a direct-play movie load consumes, with one
/// server-side subtitle track to pick.
///
/// [rejectWrite] is the server refusing the mutation; [deliverContent] false
/// is a pick whose body never arrives, which is the load failure the write
/// must not outlive. [language]/[title] shape the picked track, so a test can
/// make it untagged or give it a title. [mutationDelays] is how long the nth
/// write is held before it answers, for the tests that need two writes in the
/// air at once; see [_DelayedWriteLink].
StubLink _link({
  bool rejectWrite = false,
  bool deliverContent = true,
  String language = 'eng',
  String title = _trackTitle,
  List<Duration> mutationDelays = const [],
}) {
  return _DelayedWriteLink((request, index) {
    if (_carries(request, documentNodeMutationSetSubtitlePreference)) {
      if (rejectWrite) {
        return graphqlErrorResponse('Invalid subtitle preference');
      }
      return {
        '__typename': 'RootMutationType',
        'setSubtitlePreference': {
          '__typename': 'SubtitlePreferenceResult',
          'mediaItemId': 'movie-1',
          'preference': preferredSubtitleObject(
            mode: 'TRACK',
            language: language,
            forced: true,
            trackTitle: title,
          ),
        },
      };
    }
    if (_carries(request, documentNodeQuerySubtitleContent)) {
      return {
        '__typename': 'RootQueryType',
        'subtitleContent': deliverContent
            ? 'WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nhi\n'
            : null,
      };
    }
    if (_carries(request, documentNodeQueryMovieDetail)) {
      return movieDetailResponse(files: [
        mediaFileWithSubtitle(language: language, title: title, forced: true),
      ]);
    }
    if (_carries(request, documentNodeQueryMovieSegments)) {
      return movieSegmentsResponse();
    }
    if (_carries(request, documentNodeQuerySubtitleTrackSettings)) {
      return subtitleTrackSettingsResponse();
    }
    if (_carries(request, documentNodeQueryMovieSubtitlePreference)) {
      return subtitlePreferenceResponse();
    }
    if (_carries(request, documentNodeQueryStreamingCandidates)) {
      return streamingCandidatesResponse(duration: 5400, directPlay: true);
    }
    return <String, dynamic>{
      '__typename': 'RootMutationType',
      'updateMovieProgress': null,
    };
  }, mutationDelays);
}

/// Mounts the screen against [link] on [player] and waits for the load to
/// settle.
///
/// "Settled" is an identified point, not a timeout: the player has been opened
/// and the 500ms of fake time `_openPlayerAndStart` holds between `open()` and
/// its own detection pass has elapsed. That pass is what derives
/// `_subtitleTracks`, the list a pick names a track out of -- `selectTrack`
/// and the sheet both drop an id it does not hold.
Future<ProviderContainer> _mount(
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
  await tester.pump(const Duration(seconds: 1));
  return container;
}

/// How many subtitle sheets are on screen, which is 0 or 1.
///
/// Used as an identified point rather than a timeout: the sheet appears only
/// after the chrome's button is tapped, and disappears only once a tile tap (or
/// a dismissal) has been handled, so "it is gone" is proof the tap landed
/// rather than an empty state a missed tap would also satisfy.
int _sheetCount() => find.byType(SubtitleTrackSelectorSheet).evaluate().length;

/// Asks the mounted screen for [trackId], the way the receiver would.
///
/// A null [trackId] is the wire form of "Off" -- see `TrackSelectionIntent`'s
/// `trackId` dartdoc -- and is exactly what the remote's
/// `SelectSubtitleTrack { id: null }` becomes.
void _pickRemotely(ProviderContainer container, String? trackId) {
  container.read(remoteTargetControllerProvider).submit(
        TrackSelectionIntent(kind: TrackKind.subtitle, trackId: trackId),
      );
}

void main() {
  testWidgets(
      'a track picked from the remote is written back with its '
      'language and flags', (tester) async {
    final link = _link();
    final container = await _mount(tester, link, _ProbedPlayer());

    _pickRemotely(container, _serverTrackId);
    await pumpUntil(tester, () => _writes(link).isNotEmpty);

    expect(_writes(link), hasLength(1),
        reason: 'one pick is one preference: not once per track-list revision '
            'and not once per source switch');
    final written = _writes(link).single.variables;
    expect(written['mode'], 'TRACK');
    expect(written['language'], 'eng');
    expect(written['forced'], isTrue);
    expect(written['hearingImpaired'], isFalse);
    expect(written['trackTitle'], _trackTitle);
  });

  testWidgets(
      'a remote Off is written back as an Off, carrying nothing '
      'over', (tester) async {
    final player = _ProbedPlayer();
    final link = _link();
    final container = await _mount(tester, link, player);

    // A track first, so the Off below cannot pass by writing an Off that
    // happens to be empty anyway: there is a language, a title and two flags
    // in the previous selection for it to leak out of.
    _pickRemotely(container, _serverTrackId);
    await pumpUntil(tester, () => _writes(link).isNotEmpty);

    // Off is the one case where a wrong write is unrecoverable for the
    // viewer: a missing Off means the next episode switches subtitles back
    // on, which is the behaviour this whole feature exists to remove.
    _pickRemotely(container, null);
    await pumpUntil(tester, () => _writes(link).length >= 2);

    expect(player.selectedSubtitleTracks.last, SubtitleTrack.no(),
        reason: 'the Off has to have reached the player before it is worth '
            'anything as a stored preference');
    expect(_writes(link), hasLength(2),
        reason: 'the track and then the Off, one write each');
    final written = _writes(link).last.variables;
    expect(written['mode'], 'OFF');
    expect(written.keys.toSet(), {'fileId', 'mode'},
        reason: 'an Off names no track at all: nothing of the previous '
            'selection may be carried into it, since the server rejects an '
            'Off that arrives with a language');
  });

  testWidgets('a track picked from the sheet is written back too',
      (tester) async {
    final link = _link();
    await _mount(tester, link, _ProbedPlayer());

    await tester.tap(find.byKey(SecondaryCluster.subtitlesKey));
    await pumpUntil(tester, () => find.text(_trackTitle).evaluate().isNotEmpty);
    // The sheet's tiles exist in the tree from the first frame of the route
    // transition, while the sheet itself is still below the viewport: settle
    // the slide-up before tapping, and scroll to the tile in case the
    // sheet's 85%-of-screen body still clips it.
    await tester.pump(const Duration(milliseconds: 400));
    final tile = find.text(_trackTitle);
    await tester.ensureVisible(tile);
    await tester.pump();
    await tester.tap(tile);
    await pumpUntil(tester, () => _writes(link).isNotEmpty);

    expect(_writes(link), hasLength(1),
        reason: 'a sheet pick is as deliberate as a remote one');
    expect(_writes(link).single.variables['trackTitle'], _trackTitle);
  });

  testWidgets('a rejected write costs the preference and not the playback',
      (tester) async {
    final player = _ProbedPlayer();
    final link = _link(rejectWrite: true);
    final container = await _mount(tester, link, player);

    _pickRemotely(container, _serverTrackId);
    await pumpUntil(tester, () => _writes(link).isNotEmpty);

    // The selection still happened: the write was attempted only after the
    // track had already reached the player, and its rejection must not have
    // undone that.
    expect(player.selectedSubtitleTracks, hasLength(1));
    expect(find.textContaining('Could not'), findsNothing,
        reason: 'the viewer picked a track that is playing; a preference the '
            'server refused is not something they can act on');
  });

  testWidgets('a pick whose body never arrives is not remembered',
      (tester) async {
    final link = _link(deliverContent: false);
    final container = await _mount(tester, link, _ProbedPlayer());

    _pickRemotely(container, _serverTrackId);
    // Identified point: the failure line the viewer sees, which is the apply
    // itself finishing and failing. Anything this test asserts about the
    // write has to stand after that, not on an empty state.
    await pumpUntil(tester,
        () => find.textContaining('Could not load').evaluate().isNotEmpty);
    await tester.pump(const Duration(seconds: 1));

    expect(_writes(link), isEmpty,
        reason: 'a track that never loaded is not what this show should open '
            'on next time; the write goes after the apply for exactly this');
  });

  testWidgets('a track with no language tag is not remembered', (tester) async {
    final player = _ProbedPlayer();
    // `und` is ffprobe's "undetermined": storing it would pin the show to a
    // preference that can never match anything on the next file.
    final link = _link(language: 'und');
    final container = await _mount(tester, link, player);

    _pickRemotely(container, _serverTrackId);
    await pumpUntil(tester, () => player.selectedSubtitleTracks.isNotEmpty);
    await tester.pump(const Duration(seconds: 1));

    expect(_writes(link), isEmpty,
        reason: 'nothing usable to remember, so nothing is remembered');
  });

  testWidgets('an mpv-native pick keeps what mpv reported about it',
      (tester) async {
    final link = _link();
    final container = await _mount(tester, link, _ProbedPlayer());

    // mpv's own track, not the server's: its stream index is what would
    // translate it to the server's copy of the same stream. That index comes
    // from the native `track-list`, which no widget test has (see
    // `subtitle_stream_index_native.dart`), so this is the untranslatable
    // path: the language and title mpv published are kept, and both
    // disposition flags are false because media_kit reports neither.
    _pickRemotely(container, 'mk_${_mpvSubtitleTrack.id}');
    await pumpUntil(tester, () => _writes(link).isNotEmpty);

    expect(_writes(link), hasLength(1));
    final written = _writes(link).single.variables;
    expect(written['mode'], 'TRACK');
    expect(written['language'], 'jpn');
    expect(written['trackTitle'], 'Japanese');
    expect(written['forced'], isFalse);
    expect(written['hearingImpaired'], isFalse);
  });

  testWidgets('a sheet Off with nothing applied is applied and remembered',
      (tester) async {
    final link = _link();
    final player = _ProbedPlayer();
    await _mount(tester, link, player);

    // The contract this test used to record as a defect. With nothing applied
    // and no attempt in flight, `_pendingSubtitleSelection` is null, meaning
    // idle -- not `TargetOff()`, which is what this tap requests. The two are
    // different values, so `shouldStartSubtitleSelection` lets the tap
    // through, `_applySubtitleSelection` runs, and the write follows from it.
    // The remote-control Off path, which never had this gate, has always
    // written OFF; the two paths now agree.
    await tester.tap(find.byKey(SecondaryCluster.subtitlesKey));
    await pumpUntil(tester, () => _sheetCount() > 0);
    await tester.pump(const Duration(milliseconds: 400));
    final offTile = find.descendant(
      of: find.byType(SubtitleTrackSelectorSheet),
      matching: find.text('Off'),
    );
    await tester.ensureVisible(offTile);
    await tester.pump();
    await tester.tap(offTile);

    await pumpUntil(tester, () => _sheetCount() == 0);
    await pumpUntil(tester, () => _writes(link).isNotEmpty);

    expect(player.selectedSubtitleTracks, isNotEmpty,
        reason: 'the Off reached the player, which is the step the write '
            'follows from');
    expect(_writes(link), hasLength(1));
    expect(_writes(link).single.variables['mode'], 'OFF');
  });

  testWidgets('two picks in flight are written in the order they were made',
      (tester) async {
    // The server's upsert is unconditional, so whichever write lands last
    // wins. Without a queue, a slow first write can land after a fast second
    // one and pin the show to a choice the viewer already moved past: the
    // hold below is what gives the first write that chance.
    final link = _link(mutationDelays: [
      const Duration(milliseconds: 300),
      Duration.zero,
    ]);
    final player = _ProbedPlayer();
    final container = await _mount(tester, link, player);

    _pickRemotely(container, 'mk_${_mpvSubtitleTrack.id}');
    // The second pick is issued only once the first has taken effect. Two
    // picks submitted in the same turn are not two picks in flight: a
    // selection a later one superseded is dropped whole, and the write that
    // follows an apply it dropped is skipped, so the same-turn version of
    // this test would never get two writes to order at all. Waiting on the
    // player is the identified point that the first pick landed, and the pump
    // after it is what lets its write reach the transport, where it is then
    // held for its 300ms.
    await pumpUntil(tester, () => player.selectedSubtitleTracks.isNotEmpty);
    await tester.pump();

    _pickRemotely(container, null);

    // Both have landed: the second immediately, since it is the fast one.
    await pumpUntil(tester, () => _writes(link).length >= 2);

    expect(_writes(link).map((w) => w.variables['mode']).toList(),
        ['TRACK', 'OFF'],
        reason: 'the queue preserves the order the viewer picked in');
  });
}
