// A subtitle the stored preference selected, carried across a fallback.
//
// Reproduces an iPad session: native direct play applied the saved English
// preference by fetching the server's copy of an embedded track and
// `sub-add`ing it, mpv's list grew by one entry for the added file, and a
// fallback to transcode then lost the subtitle with no toast. The fallback
// here is driven by two stalls under Auto rather than by dropped frames:
// frame stats come from mpv's own properties, which a widget test cannot
// fake, and both reasons reach the same `_fallbackToTranscode`.

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:player/core/player/subtitle_stream_index.dart';
import 'package:player/core/remote/remote_target_controller.dart';
import 'package:player/presentation/screens/player/player_screen.dart';
import 'package:player/presentation/widgets/video_controls/playback_chrome.dart';
import 'package:player/presentation/widgets/toast/toaster.dart';

import '../../../test_utils/mock_network_images.dart';
import '../../../test_utils/probed_tracks.dart';
import '../../../test_utils/scripted_mydia_transport.dart';
import 'player_screen_test_harness.dart';

const _notCarried =
    "Couldn't keep your subtitles at this quality. Pick them again.";
const _loadFailed = 'Could not load that subtitle track. Try again.';

/// A media_kit player with no decoder behind it that answers a subtitle
/// selection the way mpv and media_kit do.
///
/// `setSubtitleTrack` records the track as current, and a data or uri track
/// (a `sub-add`) appends an external entry to mpv's list, titled and tagged
/// as media_kit asks mpv to tag it. `open` starts a new file, so it drops
/// those entries and resets the current track to `auto`.
class _MpvLikePlayer extends PlatformPlayer implements SelectedMpvSubtitle {
  _MpvLikePlayer({required this.containerSubtitles})
      : super(configuration: const PlayerConfiguration());

  /// mpv's `sid`: a `sub-add ... select` makes it the new entry's id.
  @override
  String? selectedSubtitleId;

  /// What mpv reads out of the direct-play container once [probe] runs.
  final List<SubtitleTrack> containerSubtitles;

  final opened = <Media>[];
  final subtitleTracks = <SubtitleTrack>[];

  final _handle = Completer<int>();

  @override
  Future<int> get handle => _handle.future;

  List<SubtitleTrack> _subtitles = const [];

  void _publish() {
    state = state.copyWith(
      tracks: probedTracks(subtitle: [
        SubtitleTrack.auto(),
        SubtitleTrack.no(),
        ..._subtitles,
      ]),
    );
    tracksController.add(state.tracks);
  }

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    opened.add(playable as Media);
    _subtitles = const [];
    selectedSubtitleId = null;
    state = state.copyWith(
      duration: const Duration(seconds: 90),
      position: playable.start ?? Duration.zero,
      playing: false,
      track: state.track.copyWith(subtitle: SubtitleTrack.auto()),
    );
    durationController.add(state.duration);
    positionController.add(state.position);
    playingController.add(false);
    // Video and audio straight away, subtitles only once [probe] runs: the
    // window in which the preference matched the server's list.
    _publish();
  }

  /// mpv finishes reading the container's subtitle streams.
  void probe() {
    _subtitles = [...containerSubtitles, ..._subtitles];
    _publish();
  }

  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) async {
    subtitleTracks.add(track);
    if (track.data || track.uri) {
      final nextId = [...containerSubtitles, ..._subtitles]
              .map((t) => int.tryParse(t.id) ?? 0)
              .fold<int>(0, (a, b) => a > b ? a : b) +
          1;
      _subtitles = [
        ..._subtitles,
        SubtitleTrack(
          '$nextId',
          track.title ?? 'external',
          track.language ?? 'auto',
        ),
      ];
      selectedSubtitleId = '$nextId';
    } else {
      selectedSubtitleId = int.tryParse(track.id) == null ? null : track.id;
    }
    state = state.copyWith(track: state.track.copyWith(subtitle: track));
    trackController.add(state.track);
  }

  /// What mpv reports once a frame has decoded; the embedded preference's
  /// backstop is timed from it.
  void emitFirstFrame() => widthController.add(1920);

  /// mpv publishes its revised list, with any `sub-add`ed file in it. mpv's
  /// observer reports it after the command has returned, so a test calls
  /// this once the selection has landed.
  void publishTrackList() => _publish();

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
  Future<void> seek(Duration position) async => advance(position);

  void advance(Duration position) {
    state = state.copyWith(position: position);
    positionController.add(position);
  }

  void buffering(bool value) {
    state = state.copyWith(buffering: value);
    bufferingController.add(value);
  }
}

/// A transport that can hold the first `SubtitleContent` request open, so
/// mpv's probe can land while the preference's fetch is in flight.
class _Server extends ScriptedMydiaTransport {
  _Server(super.handler);

  Completer<void>? holdSubtitleContent;
  bool subtitleContentHeld = false;

  @override
  Future<Map<String, dynamic>> send(
    String query,
    Map<String, dynamic> variables, {
    String? token,
    String? deviceProfile,
    Duration? timeout,
  }) async {
    final hold = holdSubtitleContent;
    if (hold != null &&
        ScriptedMydiaTransport.operationOf(query) == 'SubtitleContent') {
      holdSubtitleContent = null;
      subtitleContentHeld = true;
      await hold.future;
    }
    return super.send(query, variables,
        token: token, deviceProfile: deviceProfile, timeout: timeout);
  }
}

_Server _server({
  required Map<String, dynamic> file,
  String? subtitleContent = 'WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nHi\n',
}) {
  return _Server((request, index) {
    switch (request.operation) {
      case 'SubtitleContent':
        return {
          '__typename': 'RootQueryType',
          'subtitleContent': subtitleContent,
        };
      case 'MovieDetail':
        return movieDetailResponse(positionSeconds: 0, files: [file]);
      case 'MovieSubtitlePreference':
        return subtitlePreferenceResponse(preferences: {
          'file-1': preferredSubtitleObject(mode: 'TRACK', language: 'eng'),
        });
      case 'MovieSegments':
        return movieSegmentsResponse();
      case 'SubtitleTrackSettings':
        return subtitleTrackSettingsResponse();
      case 'StreamingCandidates':
        return streamingCandidatesResponse(
          directPlay: true,
          duration: 5400,
          height: 1080,
          bitrate: 8000000,
        );
    }
    final variables = request.variables;
    if (variables.containsKey('strategy')) {
      return startStreamingSessionResponse(
        sessionId: 'sess-$index',
        startPosition: variables['startPosition'] as int? ?? 0,
        duration: 5400,
      );
    }
    if (variables.containsKey('sessionId')) {
      return endStreamingSessionResponse();
    }
    return <String, dynamic>{
      '__typename': 'RootMutationType',
      'updateMovieProgress': null,
    };
  });
}

Future<RemotePlayerBinding> _mount(
  WidgetTester tester,
  _Server server,
  _MpvLikePlayer player,
) async {
  final container = buildPlayerScreenContainer(
    server: server,
    connectionState: HarnessLink.p2p(serverNodeAddr: 'test-node'),
    castManager: CapturingCastSessionManager(),
    proxyService: TrackingLocalProxyService(),
  );
  addTearDown(container.dispose);
  await pumpPlayerScreen(
    tester,
    container,
    createPlayer: () => Player(platformPlayer: player),
  );
  await pumpUntil(tester, () => player.state.playing, maxTries: 500);
  return tester.state(find.byType(PlayerScreen)) as RemotePlayerBinding;
}

/// Every message the toast layer is asked to show, however briefly.
List<String> _recordToasts(WidgetTester tester) {
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
  return shown;
}

/// Two stalls under Auto fall back to transcode, then the new source plays.
Future<void> _fallBackToTranscode(
  WidgetTester tester,
  _MpvLikePlayer player,
) async {
  Future<void> tick() => tester.pump(const Duration(seconds: 1));
  await tick(); // playback has run once
  player.buffering(true);
  await tick(); // stall 1
  player.buffering(false);
  await tick();
  player.buffering(true);
  await tick(); // stall 2
  await pumpUntil(tester, () => player.opened.length == 2);
  expect(player.opened.last.uri, contains('/hls/'),
      reason: 'the stalls must have fallen back to a transcode');

  player.buffering(false);
  player.advance(const Duration(seconds: 1));
  await tester.pump();
  player.advance(const Duration(seconds: 2));
  await tester.pump();
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump(const Duration(seconds: 1));
}

/// The viewer picks Original from the quality dialog, which overrides the
/// stall memory and direct plays again. mpv opens the file with no subtitles
/// listed until [_MpvLikePlayer.probe] runs.
Future<void> _switchToOriginal(
  WidgetTester tester,
  _MpvLikePlayer player,
) async {
  final opens = player.opened.length;
  tester.widget<PlaybackChrome>(find.byType(PlaybackChrome)).onQualityTap!();
  const originalRow = Key('quality-rung-Original');
  await pumpUntil(tester, () => find.byKey(originalRow).evaluate().isNotEmpty);
  await tester.tap(find.byKey(originalRow));
  await pumpUntil(tester, () => player.opened.length == opens + 1);
  expect(player.opened.last.uri, isNot(contains('/hls/')),
      reason: 'Original must have switched back onto direct play');

  // Increasing positions: the switch takes the first one it sees as its
  // baseline and waits for one past it, and it subscribes a pump or two
  // after the open.
  for (var at = 3; at < 9; at++) {
    player.advance(Duration(seconds: at));
    await tester.pump();
  }
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  testWidgets(
      'a preference applied from the server in direct play is shown again '
      'after a fallback to transcode', (tester) async {
    await mockHttpResponse(() async {
      final player = _MpvLikePlayer(containerSubtitles: const [
        SubtitleTrack('1', 'English', 'eng'),
        SubtitleTrack('2', 'Japanese', 'jpn'),
      ]);
      final server = _server(
        file: mediaFileWithSubtitle(
          trackId: '3',
          language: 'eng',
          title: 'English',
          url: null,
          embedded: true,
        ),
      )..holdSubtitleContent = Completer<void>();
      final hold = server.holdSubtitleContent!;

      final binding = await _mount(tester, server, player);
      final toasts = _recordToasts(tester);

      // mpv listed no subtitles, so the preference waits for it, until the
      // backstop five seconds after the first frame; then it matches the
      // server's list and fetches the embedded track's body. (On the iPad
      // this came straight at the track cap, before the backstop existed.)
      //
      // Still loading meanwhile, as the iPad was: a subtitle switch once
      // playback has run starts the policy's interruption grace, which would
      // swallow the stalls that drive the fallback below.
      player.buffering(true);
      player.emitFirstFrame();
      await tester.pump(const Duration(seconds: 5));
      await pumpUntil(tester, () => server.subtitleContentHeld);
      expect(server.subtitleContentHeld, isTrue);

      // mpv lists the container's own tracks while that fetch is open.
      player.probe();
      await tester.pump();
      hold.complete();
      await pumpUntil(tester, () => player.subtitleTracks.isNotEmpty);
      final added = player.subtitleTracks.single;
      expect(added.data, isTrue,
          reason: "the server's body was sub-added to the player");
      await tester.pump(const Duration(milliseconds: 100));
      expect(binding.describe(0).selectedSubtitle, '3');

      // mpv's list grows by one entry, for the file just added.
      player.publishTrackList();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(binding.describe(0).selectedSubtitle, '3',
          reason: "after mpv lists the added file, the selection is still the "
              "server's track, not mpv's entry for the added file or nothing");
      // `subtitleTracks` is `_subtitleTracks`, the list the subtitle sheet is
      // built from, so this is also the sheet's rows.
      final offered = binding.describe(0).subtitleTracks.map((t) => t.id);
      expect(
        offered,
        ['mk_1', 'mk_2', '3'],
        reason: "mpv's entry for the added file is listed as the server's "
            'track it copies, in its place, and not as a subtitle of its own',
      );
      expect(offered, contains(binding.describe(0).selectedSubtitle),
          reason: 'the selected subtitle is a row the viewer sees checked');

      player.buffering(false);
      await _fallBackToTranscode(tester, player);
      await pumpUntil(tester, () => player.subtitleTracks.length == 2);

      expect(player.subtitleTracks, hasLength(2),
          reason: 'the subtitle must be applied again on the transcode');
      expect(player.subtitleTracks.last, added);
      expect(binding.describe(0).selectedSubtitle, '3');
      expect(toasts, isNot(contains(_notCarried)));

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    }, responseBody: 'a.ts\nb.ts\nc.ts\n'.codeUnits);
  });

  testWidgets(
      'a carried preference that matches nothing on the new source says so',
      (tester) async {
    await mockHttpResponse(() async {
      final player = _MpvLikePlayer(containerSubtitles: const [
        SubtitleTrack('1', 'English', 'eng'),
      ]);
      // The server cannot deliver its English track as text, so a transcode
      // has no English to offer, while direct play reads mpv's own.
      final server = _server(
        file: mediaFileWithSubtitle(
          trackId: '3',
          language: 'eng',
          title: 'English',
          url: null,
          embedded: true,
          deliverable: false,
        ),
      );

      final binding = await _mount(tester, server, player);
      final toasts = _recordToasts(tester);

      player.probe();
      await pumpUntil(tester, () => player.subtitleTracks.isNotEmpty);
      expect(player.subtitleTracks.single.id, '1',
          reason: "the preference lands on mpv's own English track");
      expect(binding.describe(0).selectedSubtitle, 'mk_1');

      await _fallBackToTranscode(tester, player);
      await pumpUntil(tester, () => toasts.contains(_notCarried));

      expect(toasts, contains(_notCarried),
          reason: 'a subtitle never disappears silently');
      expect(binding.describe(0).selectedSubtitle, isNull);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    }, responseBody: 'a.ts\nb.ts\nc.ts\n'.codeUnits);
  });

  testWidgets(
      'a carried preference whose body cannot be fetched says it was not '
      'carried', (tester) async {
    await mockHttpResponse(() async {
      final player = _MpvLikePlayer(containerSubtitles: const [
        SubtitleTrack('1', 'English', 'eng'),
      ]);
      final server = _server(
        file: mediaFileWithSubtitle(
          trackId: '3',
          language: 'eng',
          title: 'English',
          url: null,
          embedded: true,
        ),
        subtitleContent: null,
      );

      final binding = await _mount(tester, server, player);
      final toasts = _recordToasts(tester);

      player.probe();
      await pumpUntil(tester, () => player.subtitleTracks.isNotEmpty);
      expect(binding.describe(0).selectedSubtitle, 'mk_1');

      await _fallBackToTranscode(tester, player);
      await pumpUntil(tester, () => toasts.contains(_notCarried));

      expect(server.of('SubtitleContent'), isNotEmpty,
          reason: "the transcode has only the server's copy to fetch");
      expect(toasts, contains(_notCarried),
          reason: 'the viewer did not pick this track at this quality, so '
              'a "try again" has nothing for them to retry');
      expect(toasts, isNot(contains(_loadFailed)));

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    }, responseBody: 'a.ts\nb.ts\nc.ts\n'.codeUnits);
  });

  group('switching back onto direct play before mpv lists subtitles', () {
    testWidgets("the carried preference waits for mpv's list", (tester) async {
      await mockHttpResponse(() async {
        final player = _MpvLikePlayer(containerSubtitles: const [
          SubtitleTrack('1', 'English', 'eng'),
        ]);
        final server = _server(
          file: mediaFileWithSubtitle(
            trackId: '3',
            language: 'eng',
            title: 'English',
            url: null,
            embedded: true,
          ),
        );

        final binding = await _mount(tester, server, player);
        final toasts = _recordToasts(tester);

        player.probe();
        await pumpUntil(tester, () => player.subtitleTracks.isNotEmpty);
        expect(binding.describe(0).selectedSubtitle, 'mk_1');

        await _fallBackToTranscode(tester, player);
        await pumpUntil(
            tester, () => binding.describe(0).selectedSubtitle == '3');
        final fetches = server.of('SubtitleContent').length;
        final selections = player.subtitleTracks.length;

        await _switchToOriginal(tester, player);

        expect(player.subtitleTracks, hasLength(selections),
            reason: 'nothing is applied before mpv lists the new file');
        expect(server.of('SubtitleContent'), hasLength(fetches));

        player.probe();
        await pumpUntil(
            tester, () => player.subtitleTracks.length > selections);
        await tester.pump(const Duration(milliseconds: 100));

        expect(player.subtitleTracks.last.id, '1',
            reason: "the preference lands on mpv's own English track");
        expect(binding.describe(0).selectedSubtitle, 'mk_1');
        expect(server.of('SubtitleContent'), hasLength(fetches),
            reason: 'mpv carries the stream, so nothing is fetched');
        expect(toasts, isNot(contains(_notCarried)));

        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      }, responseBody: 'a.ts\nb.ts\nc.ts\n'.codeUnits);
    });

    testWidgets(
        'a preference only mpv can deliver waits too, rather than saying it '
        'was not carried', (tester) async {
      await mockHttpResponse(() async {
        final player = _MpvLikePlayer(containerSubtitles: const [
          SubtitleTrack('1', 'English', 'eng'),
        ]);
        // The server cannot deliver its English track, so before mpv's probe
        // direct play has nothing English to match either.
        final server = _server(
          file: mediaFileWithSubtitle(
            trackId: '3',
            language: 'eng',
            title: 'English',
            url: null,
            embedded: true,
            deliverable: false,
          ),
        );

        final binding = await _mount(tester, server, player);
        final toasts = _recordToasts(tester);

        player.probe();
        await pumpUntil(tester, () => player.subtitleTracks.isNotEmpty);
        expect(binding.describe(0).selectedSubtitle, 'mk_1');

        await _fallBackToTranscode(tester, player);
        await pumpUntil(tester, () => toasts.contains(_notCarried));
        final toastsBefore = toasts.length;
        final selections = player.subtitleTracks.length;

        await _switchToOriginal(tester, player);

        expect(toasts.skip(toastsBefore), isNot(contains(_notCarried)),
            reason: 'mpv has not listed the file yet, so nothing is known '
                'to be missing');

        player.probe();
        await pumpUntil(
            tester,
            () =>
                player.subtitleTracks.skip(selections).any((t) => t.id == '1'));
        await tester.pump(const Duration(milliseconds: 100));

        expect(binding.describe(0).selectedSubtitle, 'mk_1');
        expect(toasts.skip(toastsBefore), isNot(contains(_notCarried)));

        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      }, responseBody: 'a.ts\nb.ts\nc.ts\n'.codeUnits);
    });
  });
}
