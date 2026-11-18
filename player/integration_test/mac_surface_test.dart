// The macOS surface path end to end: the real `PlayerScreen`, a real
// media_kit `Player`, the real `MpvSurfacePlugin` and the app's libmpv
// (gpu-next on MoltenVK), playing local files.
//
// Run on a Mac, with clips from `scripts/generate-hdr-fixtures.sh`:
//
//   flutter test integration_test/mac_surface_test.dart -d macos \
//     --dart-define=MYDIA_HDR_FIXTURES=/path/to/fixtures
//
// The fixtures directory defaults to `~/mydia-hdr/fixtures`. It needs
// `levels_hdr10.mp4`, `sdr_testsrc.mp4`, and `sdr_subs.mkv`: the SDR clip
// with one English SRT track, muxed with
// `ffmpeg -i sdr_testsrc.mp4 -i subs.srt -map 0:v -map 1:s -c:v copy -c:s srt`.
// The whole file skips anywhere but macOS, and when a clip is missing. It
// is not in `all_tests.dart`: CI's player E2E runs on Linux.
//
// Keep the Mac's displays awake for the whole run (`caffeinate -u` in a
// loop when driving it over ssh). If every display is asleep when the video
// output starts, mpv's mac output waits forever for a display link that
// never fires, and the next mpv call from Dart blocks the UI isolate.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart' show Video;
import 'package:player/core/playback/loading_step.dart';
import 'package:player/core/playback/playback_controller.dart';
import 'package:player/core/playback/playback_plan.dart';
import 'package:player/core/player/mpv_surface_channel.dart';
import 'package:player/core/player/stream_timeline.dart';
import 'package:player/core/settings/settings_service.dart';
import 'package:player/core/settings/stats_overlay_setting.dart';
import 'package:player/core/update/update_provider.dart';
import 'package:player/l10n/gen/app_localizations.dart';
import 'package:player/presentation/screens/player/player_screen.dart';
import 'package:player/presentation/screens/player/player_screen_views.dart'
    show PlayerStatsPanel;
import 'package:player/presentation/screens/player/session/playback_session_types.dart';
import 'package:player/presentation/widgets/video_surface/mydia_subtitle_view.dart';
import 'package:player/presentation/widgets/video_surface/player_video_surface.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import '../test/presentation/screens/player/player_screen_test_harness.dart';
import '../test/presentation/screens/player/session/fake_playback_session.dart';
import '../test/test_utils/mock_auth_storage.dart';
import '../test/test_utils/scripted_mydia_transport.dart';
import '../test/test_utils/toast_harness.dart';
import 'helpers/test_bootstrap.dart';

const _appVersion = '0.0.0-surface-it';

final _fixtures = () {
  const defined = String.fromEnvironment('MYDIA_HDR_FIXTURES');
  if (defined.isNotEmpty) return defined;
  return '${Platform.environment['HOME']}/mydia-hdr/fixtures';
}();

String _clip(String name) => '$_fixtures/$name';

const _hdr10 = 'levels_hdr10.mp4';
const _sdr = 'sdr_testsrc.mp4';
const _subs = 'sdr_subs.mkv';
const _subtitleText = 'Mydia surface subtitle check';

/// Why the file cannot run here, or null.
String? _skipReason() {
  if (!Platform.isMacOS) return 'the surface path is macOS only';
  for (final name in [_hdr10, _sdr, _subs]) {
    if (!File(_clip(name)).existsSync()) {
      return 'missing fixture ${_clip(name)}';
    }
  }
  return null;
}

/// One ordered record of surface calls and player disposals across every
/// player a test creates.
final _log = <String>[];

/// The plugin, with every call logged when it starts and when it returns.
class _RecordingSurface implements MpvSurface {
  final _inner = const MpvSurfaceChannel();

  Future<T> _traced<T>(String what, Future<T> Function() call) async {
    _log.add('$what start');
    try {
      return await call();
    } finally {
      _log.add('$what end');
    }
  }

  @override
  Future<void> attach(int handle, int viewId) =>
      _traced('attach $handle', () => _inner.attach(handle, viewId));

  @override
  Future<bool> awaitVideoOutput(int handle) => _traced(
      'awaitVideoOutput $handle', () => _inner.awaitVideoOutput(handle));

  @override
  Future<void> setOption(int handle, String name, String value) => _traced(
      'setOption $handle $name=$value',
      () => _inner.setOption(handle, name, value));

  @override
  Future<void> detach(int handle) =>
      _traced('detach $handle', () => _inner.detach(handle));

  @override
  Stream<DisplayInfo> get display => _inner.display;
}

/// A real player that logs its disposal under its mpv handle.
class _TracedPlayer extends Player {
  _TracedPlayer();

  int? handleValue;
  bool disposed = false;

  NativePlayer get native => platform! as NativePlayer;

  @override
  Future<void> dispose() async {
    final h = handleValue ?? await handle;
    _log.add('dispose $h start');
    await super.dispose();
    disposed = true;
    _log.add('dispose $h end');
  }
}

/// Plays one local file: the path goes to mpv as is.
class _LocalTransport extends FakeTransport {
  _LocalTransport(this.path);
  final String path;

  @override
  Future<PlaybackSource> open(PlaybackPlan plan,
      {required String fileId,
      required Duration startAt,
      Duration? totalDuration,
      void Function(LoadingStep step)? onProgress}) async {
    opened.add(plan);
    return PlaybackSource(
      url: path,
      headers: const {},
      timeline: StreamTimeline(totalDuration: totalDuration),
      fullPlaylist: false,
      seekOnOpen: true,
    );
  }
}

class _LocalSession extends FakePlaybackSession {
  _LocalSession(String path) : _transport = _LocalTransport(path);
  final _LocalTransport _transport;

  @override
  Future<CandidatesFetch> candidates(CandidateScope scope) async => (
        offer: const PlaybackOffer(
          fileId: 'part-1',
          candidates: [
            CandidateStrategy(strategy: 'DIRECT_PLAY', mime: 'video/mp4'),
          ],
          durationSeconds: 12,
        ),
        serverRejected: false,
      );

  @override
  Future<StreamingPreparation> prepareStreaming({
    required Object owner,
    required void Function(LoadingStep step) onProgress,
    required bool Function() isCurrent,
  }) async =>
      StreamingReady(StreamingSetup(
        memoryKey: 'source:local',
        progress: progress,
        createTransport: ({required bool relayed}) => _transport,
      ));
}

class _Rig {
  _Rig(this.container, this.settings);
  final ProviderContainer container;
  final SettingsService settings;
  final players = <_TracedPlayer>[];
  final surface = _RecordingSurface();

  _TracedPlayer get last => players.last;

  Player create() {
    final p = _TracedPlayer();
    players.add(p);
    unawaited(p.handle.then((h) => p.handleValue = h));
    return p;
  }
}

Future<_Rig> _rig() async {
  final settings = SettingsService(storage: MockAuthStorage());
  final container = buildPlayerScreenContainer(
    server: ScriptedMydiaTransport((request, index) => <String, dynamic>{}),
    connectionState: HarnessLink.p2p(serverNodeAddr: 'test-node'),
    castManager: CapturingCastSessionManager(),
    proxyService: TrackingLocalProxyService(),
    coreSettingsService: settings,
    appVersion: _appVersion,
  );
  addTearDown(container.dispose);
  // The version a failure is recorded under, read before any playback.
  container.read(updateProvider);
  for (var i = 0;
      i < 50 && container.read(updateProvider).currentVersion.isEmpty;
      i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  await container.read(statsOverlayEnabledProvider.future);
  await container.read(statsOverlayEnabledProvider.notifier).set(true);
  return _Rig(container, settings);
}

Future<void> _mount(WidgetTester tester, _Rig rig, String clip,
    {String fileId = 'file-1'}) async {
  await tester.pumpWidget(UncontrolledProviderScope(
    container: rig.container,
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: toastLayerBuilder,
      home: PlayerScreen(
        mediaId: 'movie-1',
        mediaType: 'movie',
        fileId: fileId,
        title: 'The Lantern Field',
        session: _LocalSession(_clip(clip)),
        createPlayer: rig.create,
        surface: rig.surface,
      ),
    ),
  ));
  await tester.pump();
}

/// Pumps real frames until [condition] holds; fails after [timeout].
Future<void> _waitFor(
  WidgetTester tester,
  String what,
  FutureOr<bool> Function() condition, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out after $timeout waiting for $what; log: $_log');
    }
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// The newest player's source opened, its tracks are known, and the screen
/// has checked that its output started.
bool _playing(_Rig rig) {
  if (rig.players.isEmpty) return false;
  final p = rig.last;
  return p.handleValue != null &&
      p.state.tracks.video.any((t) => t.id != 'auto' && t.id != 'no') &&
      _log.contains('awaitVideoOutput ${p.handleValue} end');
}

Future<String> _prop(_TracedPlayer p, String name) =>
    p.native.getProperty(name);

/// [name] once mpv reports it: `video-target-params` stays empty until the
/// output has drawn a frame.
Future<String> _settledProp(
    WidgetTester tester, _TracedPlayer p, String name) async {
  await _waitFor(
      tester, '$name to be set', () async => (await _prop(p, name)).isNotEmpty,
      timeout: const Duration(seconds: 5));
  return _prop(p, name);
}

/// Unmounts the screen, and returns how long until every player it made was
/// disposed.
Future<Duration> _close(WidgetTester tester, _Rig rig) async {
  final watch = Stopwatch()..start();
  await tester.pumpWidget(const SizedBox());
  await _waitFor(
      tester, 'players disposed', () => rig.players.every((p) => p.disposed),
      timeout: const Duration(seconds: 15));
  return watch.elapsed;
}

/// Moves the window onto the built-in panel, the Mac's only EDR screen
/// here. Returns that display's name, or null when there is none.
Future<String?> _moveToBuiltInDisplay() async {
  final displays = await screenRetriever.getAllDisplays();
  for (final d in displays) {
    debugPrint('[mac_surface_test] display ${d.name} at '
        '${d.visiblePosition} size ${d.size}');
  }
  final builtIn = displays
      .where((d) =>
          (d.name ?? '').contains('Built-in') ||
          (d.name ?? '').contains('Color LCD'))
      .firstOrNull;
  if (builtIn == null) return null;
  final origin = builtIn.visiblePosition ?? Offset.zero;
  await windowManager
      .setBounds(Rect.fromLTWH(origin.dx + 40, origin.dy + 40, 1280, 720));
  return builtIn.name;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final skip = _skipReason();
  if (skip != null) {
    test('macOS surface', () {}, skip: skip);
    return;
  }

  setUpAll(() async {
    await ensureTestBootstrap();
    // `main` does this in the app; window_manager crashes without it.
    await windowManager.ensureInitialized();
  });
  setUp(_log.clear);

  testWidgets('HDR10 plays through gpu-next with PQ output', (tester) async {
    final display = await _moveToBuiltInDisplay();
    debugPrint('[mac_surface_test] window moved to: $display');
    final rig = await _rig();

    await _mount(tester, rig, _hdr10);
    await _waitFor(tester, 'HDR10 tracks', () => _playing(rig));
    // Gives the output a few frames and the display event time to land.
    await tester.pump(const Duration(seconds: 2));

    final p = rig.last;
    final vo = await _prop(p, 'current-vo');
    final gamma = await _settledProp(tester, p, 'video-target-params/gamma');
    final prim = await _prop(p, 'video-target-params/primaries');
    final hwdec = await _prop(p, 'hwdec-current');
    debugPrint('[mac_surface_test] hdr10 current-vo=$vo gamma=$gamma '
        'primaries=$prim hwdec-current=$hwdec');
    expect(vo, 'gpu-next');
    expect(gamma, 'pq');

    expect(find.byType(Video), findsNothing);
    expect(find.byType(PlayerVideoSurface), findsOneWidget);
    expect(await rig.settings.getMacSurfaceFailedVersion(), isNull);

    final panel = find.byType(PlayerStatsPanel);
    expect(panel, findsOneWidget);
    final headroom =
        tester.widget<PlayerStatsPanel>(panel).statsContext().outputHeadroom;
    debugPrint('[mac_surface_test] stats headroom=$headroom on $display');
    if (display != null) {
      expect(headroom, isNotNull);
      expect(headroom!, greaterThan(1.0),
          reason: 'the built-in panel offers EDR headroom');
    }

    final took = await _close(tester, rig);
    debugPrint('[mac_surface_test] close took $took; log: $_log');
  });

  testWidgets('SDR plays through gpu-next, and fill sets panscan',
      (tester) async {
    final rig = await _rig();
    await _mount(tester, rig, _sdr);
    await _waitFor(tester, 'SDR tracks', () => _playing(rig));
    final p = rig.last;
    expect(await _prop(p, 'current-vo'), 'gpu-next');
    expect(find.byType(Video), findsNothing);

    final before = await _prop(p, 'panscan');
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await _waitFor(tester, 'panscan to change',
        () async => await _prop(p, 'panscan') != before);
    final after = await _prop(p, 'panscan');
    debugPrint('[mac_surface_test] panscan $before -> $after');
    final filled = after.startsWith('1') ? after : before;
    expect(double.parse(filled), 1.0);
    // Back to whatever it was, so the stored preference is unchanged.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await _waitFor(tester, 'panscan back',
        () async => await _prop(p, 'panscan') == before);

    await _close(tester, rig);
  });

  testWidgets('a text subtitle shows in MydiaSubtitleView', (tester) async {
    final rig = await _rig();
    await _mount(tester, rig, _subs);
    await _waitFor(tester, 'subtitle clip tracks', () => _playing(rig));
    final p = rig.last;
    final track = p.state.tracks.subtitle
        .firstWhere((t) => t.id != 'auto' && t.id != 'no');
    if (p.state.track.subtitle.id != track.id) {
      await p.setSubtitleTrack(track);
    }
    await _waitFor(
      tester,
      'subtitle text',
      () => find
          .descendant(
              of: find.byType(MydiaSubtitleView),
              matching: find.textContaining(_subtitleText))
          .evaluate()
          .isNotEmpty,
    );
    // Flutter draws a text track; mpv drawing it too would double it.
    expect(await _prop(p, 'sub-visibility'), 'no');
    await _close(tester, rig);
  });

  testWidgets('fullscreen keeps the one surface view', (tester) async {
    final rig = await _rig();
    await _mount(tester, rig, _sdr);
    await _waitFor(tester, 'SDR tracks', () => _playing(rig));
    final p = rig.last;
    final h = p.handleValue;
    final before = await windowManager.getBounds();
    debugPrint('[mac_surface_test] bounds before fullscreen $before '
        'osd ${await _prop(p, 'osd-dimensions')}');

    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await _waitFor(tester, 'fullscreen', windowManager.isFullScreen,
        timeout: const Duration(seconds: 10));
    // The transition animates; let it finish and draw.
    await tester.pump(const Duration(seconds: 2));
    expect(tester.takeException(), isNull);
    expect(find.byType(PlayerVideoSurface), findsOneWidget);
    expect(await _prop(p, 'current-vo'), 'gpu-next');
    final fullscreenSize = await _prop(p, 'osd-dimensions/w');

    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await _waitFor(
        tester, 'windowed', () async => !await windowManager.isFullScreen(),
        timeout: const Duration(seconds: 10));
    await tester.pump(const Duration(seconds: 2));
    expect(tester.takeException(), isNull);
    expect(await _prop(p, 'current-vo'), 'gpu-next');
    // Logged, not asserted: with the Mac's screen locked AppKit skips the
    // transition, the frame never changes, and leaving fullscreen can put
    // the window back at a frame of its own choosing, on either output
    // path. Whether the picture follows the window is for a person to see.
    debugPrint('[mac_surface_test] fullscreen osd width $fullscreenSize; '
        'after: bounds ${await windowManager.getBounds()} '
        'osd ${await _prop(p, 'osd-dimensions')}');
    // No detach happened along the way: the view survived.
    expect(_log.where((e) => e.startsWith('detach $h')), isEmpty);

    await _close(tester, rig);
    await windowManager.setBounds(before);
  });

  testWidgets('closing mid-playback detaches first and does not hang',
      (tester) async {
    final rig = await _rig();
    await _mount(tester, rig, _hdr10);
    await _waitFor(tester, 'tracks', () => _playing(rig));
    await tester.pump(const Duration(seconds: 1));
    final h = rig.last.handleValue;

    final took = await _close(tester, rig);
    debugPrint('[mac_surface_test] close took $took; log: $_log');
    expect(took, lessThan(const Duration(seconds: 5)));
    expect(
        _log,
        containsAllInOrder(
            ['detach $h start', 'detach $h end', 'dispose $h start']));
  });

  testWidgets('the next source detaches the old handle before attaching',
      (tester) async {
    final rig = await _rig();
    await _mount(tester, rig, _sdr, fileId: 'file-a');
    await _waitFor(tester, 'first source', () => _playing(rig));
    final first = rig.last;
    final h1 = first.handleValue;

    await _mount(tester, rig, _hdr10, fileId: 'file-b');
    await _waitFor(tester, 'second source',
        () => rig.players.length == 2 && _playing(rig));
    final second = rig.last;
    final h2 = second.handleValue;
    debugPrint('[mac_surface_test] next source log: $_log');

    expect(h2, isNot(h1));
    expect(
      _log,
      containsAllInOrder([
        'detach $h1 start',
        'detach $h1 end',
        'dispose $h1 start',
        'attach $h2 start',
      ]),
    );
    expect(await _prop(second, 'current-vo'), 'gpu-next');
    expect(
        await _settledProp(tester, second, 'video-target-params/gamma'), 'pq');

    await _close(tester, rig);
  });

  testWidgets('ten open and close cycles in a row', (tester) async {
    for (var i = 0; i < 10; i++) {
      _log.clear();
      final rig = await _rig();
      await _mount(tester, rig, i.isEven ? _hdr10 : _sdr);
      await _waitFor(tester, 'cycle $i tracks', () => _playing(rig));
      expect(await _prop(rig.last, 'current-vo'), 'gpu-next',
          reason: 'cycle $i');
      final took = await _close(tester, rig);
      debugPrint('[mac_surface_test] cycle $i closed in $took');
      expect(took, lessThan(const Duration(seconds: 5)), reason: 'cycle $i');
    }
  });

  testWidgets('the escape hatch puts a new playback on the texture path',
      (tester) async {
    final rig = await _rig();
    await rig.settings.setLegacyMacVideoOutput(true);
    await _mount(tester, rig, _sdr);
    await _waitFor(
      tester,
      'texture playback',
      () =>
          rig.players.isNotEmpty &&
          rig.last.state.tracks.video
              .any((t) => t.id != 'auto' && t.id != 'no') &&
          find.byType(Video).evaluate().isNotEmpty,
    );
    expect(find.byType(PlayerVideoSurface), findsNothing);
    expect(_log.where((e) => e.startsWith('attach')), isEmpty);
    final vo = await _prop(rig.last, 'current-vo');
    debugPrint('[mac_surface_test] hatch current-vo=$vo');
    expect(vo, isNot('gpu-next'));
    await _close(tester, rig);
  });
}
