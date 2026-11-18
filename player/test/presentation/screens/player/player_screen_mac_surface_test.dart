// The player screen on the macOS surface path: mpv draws through gpu-next
// into a platform view, so no `VideoController` exists, and the screen owns
// attach, detach, panscan and the fall back to the texture path.
//
// The path is forced through `PlayerScreen.outputPath`, so these run on the
// Linux test host. `AppKitView` asks the engine for a view over
// `SystemChannels.platform_views`, which is mocked here to accept it.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart' show Video;
import 'package:player/core/player/mac_video_output.dart';
import 'package:player/core/player/mpv_surface_channel.dart';
import 'package:player/core/player/video_scaling.dart';
import 'package:player/core/p2p/media_proxy_factory.dart';
import 'package:player/core/settings/settings_service.dart';
import 'package:player/core/settings/stats_overlay_setting.dart';
import 'package:player/core/sources/mydia/mydia_source.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/l10n/gen/app_localizations.dart';
import 'package:player/presentation/screens/player/player_screen.dart';
import 'package:player/presentation/screens/player/player_screen_views.dart'
    show PlayerStatsPanel;
import 'package:player/presentation/screens/player/session/mydia_playback_session.dart';
import 'package:player/presentation/widgets/video_controls/playback_chrome.dart';
import 'package:player/presentation/widgets/video_surface/player_video_surface.dart';

import '../../../test_utils/mock_auth_storage.dart';
import '../../../test_utils/mydia_test_source.dart';
import '../../../test_utils/probed_tracks.dart';
import '../../../test_utils/scripted_mydia_transport.dart';
import '../../../test_utils/toast_harness.dart';
import 'player_screen_test_harness.dart';

const _appVersion = '1.7.0';

/// One ordered record of what the screen asked the surface and the players
/// to do, so ordering across them can be asserted.
final _log = <String>[];

/// Handles whose player has listed its tracks, which the fake plugin needs
/// before it can answer a start check.
final _listedTracks = <int>{};

class _FakeSurface implements MpvSurface {
  _FakeSurface({
    this.start = VideoOutputStart.started,
    this.attachError,
    this.startByHandle = const {},
  });

  /// What [awaitVideoOutput] answers.
  VideoOutputStart start;

  /// Per-handle answers that take precedence over [start].
  final Map<int, VideoOutputStart> startByHandle;

  /// Holds every [detach] until completed, when set.
  Completer<void>? detachGate;

  /// Thrown by [attach] when set, the way the plugin refuses (`no-view`).
  final PlatformException? attachError;

  final setOptions = <(int, String, String)>[];

  @override
  Future<void> attach(int handle, int viewId) async {
    _log.add('attach $handle');
    await attachGate?.future;
    _log.add('attached $handle');
    final error = attachError;
    if (error != null) throw error;
  }

  /// Holds every [attach] reply until completed, when set.
  Completer<void>? attachGate;

  /// Holds [awaitVideoOutput]'s answer until completed, when set.
  Completer<void>? startGate;

  @override
  Future<VideoOutputStart> awaitVideoOutput(int handle) async {
    _log.add('awaitVideoOutput $handle');
    // The plugin can tell an audio-only source from a video one only once
    // mpv has listed the tracks; a probe before that is a check that could
    // not run.
    if (!_listedTracks.contains(handle)) return VideoOutputStart.timedOut;
    await startGate?.future;
    return startByHandle[handle] ?? start;
  }

  @override
  Future<void> setOption(int handle, String name, String value) async {
    setOptions.add((handle, name, value));
  }

  @override
  Future<void> detach(int handle) async {
    _log.add('detach $handle');
    await detachGate?.future;
  }

  // ignore: close_sinks
  final displays = StreamController<DisplayInfo>.broadcast();

  @override
  Stream<DisplayInfo> get display => displays.stream;
}

/// A media_kit player with no decoder. [handleValue] null keeps the handle
/// unresolved, which is what a texture-path player needs under test so
/// `VideoController` never reaches native code.
class _FakePlayer extends PlatformPlayer {
  _FakePlayer({
    this.handleValue,
    this.withVideo = true,
    this.tracksOnOpen = true,
  }) : super(configuration: const PlayerConfiguration()) {
    final value = handleValue;
    if (value != null) _handle.complete(value);
  }

  final int? handleValue;
  final bool withVideo;

  /// Whether [open] lists the tracks; otherwise [publishTracks] does.
  final bool tracksOnOpen;
  final _handle = Completer<int>();
  bool opened = false;
  bool disposed = false;

  @override
  Future<int> get handle => _handle.future;

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    _log.add('open ${handleValue ?? 'texture'}');
    opened = true;
    state = state.copyWith(
      duration: const Duration(seconds: 90),
      position: Duration.zero,
      playing: play,
    );
    durationController.add(state.duration);
    positionController.add(state.position);
    playingController.add(play);
    if (tracksOnOpen) publishTracks();
  }

  /// Lists the source's tracks, as mpv does once it has probed the file.
  void publishTracks() {
    final probed = probedTracks();
    state = state.copyWith(
      tracks: withVideo
          ? probed
          : Tracks(
              video: const [], audio: probed.audio, subtitle: probed.subtitle),
    );
    final value = handleValue;
    if (value != null) _listedTracks.add(value);
    tracksController.add(state.tracks);
  }

  @override
  Future<void> play() async {
    state = state.copyWith(playing: true);
    playingController.add(true);
  }

  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) async {}

  /// Reports a playback error, as mpv does for a decoder fault.
  void fail(String message) => errorController.add(message);

  @override
  // ignore: must_call_super
  Future<void> dispose() async {
    _log.add('dispose ${handleValue ?? 'texture'}');
    disposed = true;
  }
}

ScriptedMydiaTransport _server() {
  return ScriptedMydiaTransport((request, index) {
    if (request.operation == 'MovieDetail') {
      return movieDetailResponse(positionSeconds: 0);
    }
    if (request.operation == 'MovieSegments') return movieSegmentsResponse();
    if (request.operation == 'SubtitleTrackSettings') {
      return subtitleTrackSettingsResponse();
    }
    if (request.operation == 'MovieSubtitlePreference') {
      return subtitlePreferenceResponse();
    }
    if (request.operation == 'StreamingCandidates') {
      final id = request.variables['id'] as String? ?? 'file-1';
      return streamingCandidatesResponse(
          directPlay: true, duration: 5400, fileId: id);
    }
    return <String, dynamic>{
      '__typename': 'RootMutationType',
      'updateMovieProgress': null,
    };
  });
}

/// Accepts every platform view the screen creates.
void _mockPlatformViews(WidgetTester tester) {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform_views,
    (call) async => null,
  );
  addTearDown(() => tester.binding.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform_views, null));
}

class _Rig {
  _Rig(this.container, this.settings, this.server);
  final ProviderContainer container;
  final SettingsService settings;
  final ScriptedMydiaTransport server;
}

_Rig _rig() {
  final settings = SettingsService(storage: MockAuthStorage());
  final server = _server();
  final container = buildPlayerScreenContainer(
    server: server,
    connectionState: HarnessLink.p2p(serverNodeAddr: 'test-node'),
    castManager: CapturingCastSessionManager(),
    proxyService: TrackingLocalProxyService(),
    coreSettingsService: settings,
    appVersion: _appVersion,
  );
  addTearDown(container.dispose);
  // `updateProvider` is deliberately not read: its version is still empty
  // until its own read lands, and the screen must not depend on that.
  return _Rig(container, settings, server);
}

Future<void> _mount(
  WidgetTester tester,
  _Rig rig, {
  required Player Function() createPlayer,
  required MpvSurface surface,
  VideoOutputPath Function()? outputPath,
  String fileId = 'file-1',
}) async {
  final container = rig.container;
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: toastLayerBuilder,
      home: PlayerScreen(
        mediaId: 'movie-1',
        mediaType: 'movie',
        fileId: fileId,
        title: 'The Long Aurora',
        session: MydiaPlaybackSession(
          source: container.read(mediaSourceProvider(testMydiaSourceId))
              as MydiaSource,
          item: const ItemRef(
            sourceId: testMydiaSourceId,
            kind: ItemKind.movie,
            externalId: 'movie-1',
          ),
          fileId: fileId,
          proxy: () => container.read(mediaProxyProvider),
        ),
        createPlayer: createPlayer,
        surface: surface,
        outputPath: outputPath ?? () => VideoOutputPath.surface,
      ),
    ),
  ));
  await tester.pump();
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

bool _playing() => find.byType(PlaybackChrome).evaluate().isNotEmpty;

void main() {
  setUp(() {
    _log.clear();
    _listedTracks.clear();
  });

  testWidgets('the player opens only once attach has replied', (tester) async {
    _mockPlatformViews(tester);
    final rig = _rig();
    final fake = _FakePlayer(handleValue: 13);
    final surface = _FakeSurface()..attachGate = Completer<void>();

    await _mount(tester, rig,
        createPlayer: () => Player(platformPlayer: fake), surface: surface);
    await pumpUntil(tester, () => _log.contains('attach 13'));
    expect(_log, contains('attach 13'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(fake.opened, isFalse, reason: 'attach has not replied yet');

    surface.attachGate!.complete();
    await pumpUntil(tester, _playing);
    expect(_log, containsAllInOrder(['attached 13', 'open 13']));

    await _unmount(tester);
  });

  testWidgets('the start check waits for the track list, not just open',
      (tester) async {
    _mockPlatformViews(tester);
    final rig = _rig();
    final fake =
        _FakePlayer(handleValue: 14, withVideo: false, tracksOnOpen: false);

    await _mount(tester, rig,
        createPlayer: () => Player(platformPlayer: fake),
        surface: _FakeSurface());
    await pumpUntil(tester, () => fake.opened);
    await tester.pump(const Duration(milliseconds: 500));
    expect(_log, isNot(contains('awaitVideoOutput 14')),
        reason: 'mpv has not listed the tracks yet');

    fake.publishTracks();
    await pumpUntil(tester, _playing);

    expect(_log, contains('awaitVideoOutput 14'));
    expect(find.byType(PlayerVideoSurface), findsOneWidget,
        reason: 'an audio-only source is no surface failure');
    await tester.runAsync(() async {
      expect(await rig.settings.getMacSurfaceFailedVersion(), isNull);
    });

    await _unmount(tester);
  });

  testWidgets(
      'the surface path builds no VideoController and attaches '
      'before open', (tester) async {
    _mockPlatformViews(tester);
    final rig = _rig();
    final fake = _FakePlayer(handleValue: 11);
    final surface = _FakeSurface();

    await _mount(tester, rig,
        createPlayer: () => Player(platformPlayer: fake), surface: surface);
    await pumpUntil(tester, _playing);

    expect(find.byType(PlayerVideoSurface), findsOneWidget);
    expect(find.byType(Video), findsNothing);
    expect(fake.isVideoControllerAttached, isFalse,
        reason: 'constructing a VideoController marks the player attached');
    expect(_log,
        containsAllInOrder(['attach 11', 'open 11', 'awaitVideoOutput 11']));

    await _unmount(tester);
  });

  testWidgets('dispose detaches the surface before disposing the player',
      (tester) async {
    _mockPlatformViews(tester);
    final rig = _rig();
    final fake = _FakePlayer(handleValue: 12);

    await _mount(tester, rig,
        createPlayer: () => Player(platformPlayer: fake),
        surface: _FakeSurface());
    await pumpUntil(tester, _playing);
    await _unmount(tester);
    await tester.runAsync(() => pumpUntilReal(tester, () => fake.disposed));

    expect(_log, containsAllInOrder(['detach 12', 'dispose 12']));
  });

  testWidgets('nextSourceDetachesOldHandleBeforeAttachingNew', (tester) async {
    _mockPlatformViews(tester);
    final rig = _rig();
    final players = <_FakePlayer>[];
    Player next() {
      final p = _FakePlayer(handleValue: 20 + players.length);
      players.add(p);
      return Player(platformPlayer: p);
    }

    final surface = _FakeSurface();
    await _mount(tester, rig,
        createPlayer: next, surface: surface, fileId: 'file-a');
    await pumpUntil(tester, _playing);
    await _mount(tester, rig,
        createPlayer: next, surface: surface, fileId: 'file-b');
    await tester.runAsync(() =>
        pumpUntilReal(tester, () => players.length == 2 && players[1].opened));

    expect(
      _log,
      containsAllInOrder(['detach 20', 'dispose 20', 'attach 21', 'open 21']),
    );

    await _unmount(tester);
  });

  testWidgets('the stats context carries the surface display headroom',
      (tester) async {
    _mockPlatformViews(tester);
    final rig = _rig();
    await rig.container.read(statsOverlayEnabledProvider.future);
    await rig.container.read(statsOverlayEnabledProvider.notifier).set(true);
    final fake = _FakePlayer(handleValue: 41);
    final surface = _FakeSurface();
    addTearDown(surface.displays.close);

    await _mount(tester, rig,
        createPlayer: () => Player(platformPlayer: fake), surface: surface);
    await pumpUntil(tester, _playing);
    await tester.pump(const Duration(seconds: 1));

    final panel = find.byType(PlayerStatsPanel);
    expect(panel, findsOneWidget);
    expect(surface.displays.hasListener, isTrue);
    PlayerStatsPanel widget() => tester.widget<PlayerStatsPanel>(panel);
    expect(widget().statsContext().outputHeadroom, isNull,
        reason: 'no display reading yet is not a headroom of 1');

    surface.displays.add(const DisplayInfo(
      edrHeadroom: 4.0,
      potentialHeadroom: 8.0,
      screenName: 'Test',
    ));
    await tester.pump();
    expect(widget().statsContext().outputHeadroom, 4.0);

    await _unmount(tester);
  });

  testWidgets('surfaceStartFailureFallsBackToTexture', (tester) async {
    _mockPlatformViews(tester);
    final rig = _rig();
    await rig.container.read(statsOverlayEnabledProvider.future);
    await rig.container.read(statsOverlayEnabledProvider.notifier).set(true);
    final players = <_FakePlayer>[];
    Player next() {
      // Only the surface player resolves its handle; the texture player's
      // stays pending so `VideoController` never reaches native code.
      final p = _FakePlayer(handleValue: players.isEmpty ? 31 : null);
      players.add(p);
      return Player(platformPlayer: p);
    }

    await _mount(tester, rig,
        createPlayer: next,
        surface: _FakeSurface(start: VideoOutputStart.failed));
    await tester.runAsync(() =>
        pumpUntilReal(tester, () => players.length == 2 && players[1].opened));
    await pumpUntil(tester, _playing);
    await tester.pump(const Duration(seconds: 1));

    expect(find.byType(Video), findsOneWidget);
    expect(find.byType(PlayerVideoSurface), findsNothing);
    expect(_log, containsAllInOrder(['detach 31', 'dispose 31']));
    expect(players[1].isVideoControllerAttached, isTrue);
    await tester.runAsync(() async {
      expect(await rig.settings.getMacSurfaceFailedVersion(), _appVersion);
    });
    expect(
      find.text('Using the standard video output: the HDR renderer could '
          'not start on this Mac'),
      findsOneWidget,
    );

    await _unmount(tester);
  });

  testWidgets(
      'a slow start falls back to texture for this playback and records '
      'nothing', (tester) async {
    _mockPlatformViews(tester);
    final rig = _rig();
    final players = <_FakePlayer>[];
    Player next() {
      final p = _FakePlayer(handleValue: players.isEmpty ? 61 : null);
      players.add(p);
      return Player(platformPlayer: p);
    }

    await _mount(tester, rig,
        createPlayer: next,
        surface: _FakeSurface(start: VideoOutputStart.timedOut));
    await tester.runAsync(() =>
        pumpUntilReal(tester, () => players.length == 2 && players[1].opened));
    await pumpUntil(tester, _playing);

    expect(find.byType(Video), findsOneWidget);
    expect(find.byType(PlayerVideoSurface), findsNothing);
    expect(_log, containsAllInOrder(['detach 61', 'dispose 61']));
    await tester.runAsync(() async {
      expect(await rig.settings.getMacSurfaceFailedVersion(), isNull,
          reason: 'an output that is only slow to start is no failure');
    });

    await _unmount(tester);
  });

  testWidgets(
      'a refused attach falls back to texture for this playback and '
      'records nothing', (tester) async {
    _mockPlatformViews(tester);
    final rig = _rig();
    final players = <_FakePlayer>[];
    Player next() {
      final p = _FakePlayer(handleValue: players.isEmpty ? 71 : null);
      players.add(p);
      return Player(platformPlayer: p);
    }

    await _mount(
      tester,
      rig,
      createPlayer: next,
      surface: _FakeSurface(
        attachError: PlatformException(code: 'no-view'),
      ),
    );
    await tester.runAsync(() =>
        pumpUntilReal(tester, () => players.length == 2 && players[1].opened));
    await pumpUntil(tester, _playing);

    expect(find.byType(Video), findsOneWidget);
    expect(find.byType(PlayerVideoSurface), findsNothing);
    expect(players[0].opened, isFalse,
        reason: 'the fallback happens before the surface player opens');
    expect(_log, containsAllInOrder(['attach 71', 'detach 71', 'dispose 71']));
    expect(_log, isNot(contains('awaitVideoOutput 71')));
    await tester.runAsync(() async {
      expect(await rig.settings.getMacSurfaceFailedVersion(), isNull,
          reason: 'only gpu-next not starting is a version-wide failure');
    });

    await _unmount(tester);
  });

  testWidgets(
      'a slow start superseded during its detach leaves the next file '
      'on the surface', (tester) async {
    _mockPlatformViews(tester);
    final rig = _rig();
    final players = <_FakePlayer>[];
    Player next() {
      final p = _FakePlayer(handleValue: 81 + players.length);
      players.add(p);
      return Player(platformPlayer: p);
    }

    final surface =
        _FakeSurface(startByHandle: const {81: VideoOutputStart.timedOut})
          ..detachGate = Completer<void>();
    await _mount(tester, rig,
        createPlayer: next, surface: surface, fileId: 'file-a');
    await tester.runAsync(
        () => pumpUntilReal(tester, () => _log.contains('detach 81')));
    expect(_log, contains('detach 81'));

    // The viewer moves on while the slow playback is still tearing down.
    await _mount(tester, rig,
        createPlayer: next, surface: surface, fileId: 'file-b');
    surface.detachGate!.complete();
    await tester.runAsync(() =>
        pumpUntilReal(tester, () => players.length == 2 && players[1].opened));
    await pumpUntil(tester, _playing);

    expect(_log, containsAllInOrder(['attach 82', 'open 82']),
        reason: 'the texture retry belonged to the playback that timed out');
    expect(find.byType(PlayerVideoSurface), findsOneWidget);

    await _unmount(tester);
  });

  testWidgets(
      'a fault during the start check does not start a transcode '
      'when the surface falls back', (tester) async {
    _mockPlatformViews(tester);
    final rig = _rig();
    final players = <_FakePlayer>[];
    Player next() {
      final p = _FakePlayer(handleValue: players.isEmpty ? 91 : null);
      players.add(p);
      return Player(platformPlayer: p);
    }

    final surface = _FakeSurface(start: VideoOutputStart.failed)
      ..startGate = Completer<void>();
    await _mount(tester, rig, createPlayer: next, surface: surface);
    await pumpUntil(tester, () => _log.contains('awaitVideoOutput 91'));
    expect(_log, contains('awaitVideoOutput 91'));

    // The output failing to come up can surface as a playback error too.
    players[0].fail('vo: failed to initialize');
    await tester.pump(const Duration(seconds: 2));
    surface.startGate!.complete();
    await tester.runAsync(() =>
        pumpUntilReal(tester, () => players.length == 2 && players[1].opened));
    await pumpUntil(tester, _playing);

    expect(find.byType(Video), findsOneWidget);
    expect(
      rig.server.requests.where((r) => r.variables.containsKey('strategy')),
      isEmpty,
      reason: 'the texture fallback decides; no transcode on top of it',
    );

    await _unmount(tester);
  });

  testWidgets('audioOnlySourceNeverReportsSurfaceFailure', (tester) async {
    _mockPlatformViews(tester);
    final rig = _rig();
    final fake = _FakePlayer(handleValue: 41, withVideo: false);

    await _mount(tester, rig,
        createPlayer: () => Player(platformPlayer: fake),
        surface: _FakeSurface());
    await pumpUntil(tester, _playing);

    expect(find.byType(PlayerVideoSurface), findsOneWidget);
    expect(_log, containsAllInOrder(['open 41', 'awaitVideoOutput 41']),
        reason: 'the start check runs once mpv has listed the tracks');
    await tester.runAsync(() async {
      expect(await rig.settings.getMacSurfaceFailedVersion(), isNull);
    });

    await _unmount(tester);
  });

  testWidgets('pathIsFixedPerPlayback', (tester) async {
    _mockPlatformViews(tester);
    final rig = _rig();
    final fake = _FakePlayer(handleValue: 51);
    var hatch = false;

    await _mount(
      tester,
      rig,
      createPlayer: () => Player(platformPlayer: fake),
      surface: _FakeSurface(),
      outputPath: () =>
          hatch ? VideoOutputPath.texture : VideoOutputPath.surface,
    );
    await pumpUntil(tester, _playing);

    hatch = true;
    await tester.pump(const Duration(seconds: 1));

    expect(find.byType(PlayerVideoSurface), findsOneWidget);
    expect(find.byType(Video), findsNothing);
    expect(_log, isNot(contains('detach 51')));

    await _unmount(tester);
  });

  testWidgets('fit and fill set panscan on the surface', (tester) async {
    _mockPlatformViews(tester);
    // The screen loads the saved scaling and the taps save it: an empty
    // in-memory box keeps both off disk and starts from Fit.
    final box = (await tester.runAsync(() =>
        Hive.openBox<String>(VideoScalingPrefs.boxName, bytes: Uint8List(0))))!;
    addTearDown(() => tester.runAsync(box.close));
    final rig = _rig();
    final fake = _FakePlayer(handleValue: 61);
    final surface = _FakeSurface();

    await _mount(tester, rig,
        createPlayer: () => Player(platformPlayer: fake), surface: surface);
    await pumpUntil(tester, _playing);
    await tester.pump(const Duration(milliseconds: 100));

    expect(surface.setOptions, contains((61, 'panscan', '0.0')),
        reason: 'the initial scaling is sent once attached');

    final chrome = tester.widget<PlaybackChrome>(find.byType(PlaybackChrome));
    chrome.onScalingTap!();
    await tester.pump();
    expect(surface.setOptions.last, (61, 'panscan', '1.0'));

    chrome.onScalingTap!();
    await tester.pump();
    expect(surface.setOptions.last, (61, 'panscan', '0.0'));

    await _unmount(tester);
  });
}
