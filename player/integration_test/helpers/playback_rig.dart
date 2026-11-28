// The real `PlayerScreen` on a real media_kit `Player`, playing a local
// file: the Linux E2E's playback rig.
//
// Modelled on `mac_surface_test.dart`'s private rig, minus the macOS surface:
// on Linux the screen takes the texture path, through media_kit_video's
// `VideoController`, exactly as it does in the shipped app. The server side
// is scripted (no requests are expected) and the session hands the screen a
// local path, so nothing here touches the network.
//
// The clips come from `scripts/e2e/run-tests.sh`, which writes them with
// ffmpeg and passes their directory as `--dart-define=MYDIA_E2E_CLIPS`.
//
// On Linux the rig also captures the process's native stderr while it is
// mounted ([PlaybackRig.nativeStderr]). media_kit_video's Linux video output
// reports its render path decisions there with `g_printerr`, and
// `flutter test -d linux` shows none of the app's native stderr.

import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:player/core/playback/loading_step.dart';
import 'package:player/core/playback/playback_controller.dart';
import 'package:player/core/playback/playback_plan.dart';
import 'package:player/core/player/stream_timeline.dart';
import 'package:player/core/settings/settings_service.dart';
import 'package:player/l10n/gen/app_localizations.dart';
import 'package:player/l10n/locale_aliases.dart';
import 'package:player/presentation/screens/player/player_screen.dart';
import 'package:player/presentation/screens/player/session/playback_session_types.dart';

import '../../test/presentation/screens/player/player_screen_test_harness.dart'
    show
        CapturingCastSessionManager,
        HarnessLink,
        TrackingLocalProxyService,
        buildPlayerScreenContainer;
import '../../test/presentation/screens/player/session/fake_playback_session.dart';
import '../../test/test_utils/mock_auth_storage.dart';
import '../../test/test_utils/scripted_mydia_transport.dart';
import '../../test/test_utils/toast_harness.dart';

/// Where the clips are, or empty when the run was given none.
const e2eClipsDir = String.fromEnvironment('MYDIA_E2E_CLIPS');

/// testsrc2, 1280x720, 24 fps, 10 s, H.264 with a sine audio track.
const sdrClip = 'e2e_sdr.mp4';

/// [sdrClip]'s video with one English SRT cue over the whole clip.
const subsClip = 'e2e_subs.mkv';

/// The text of [subsClip]'s only cue.
const subtitleText = 'Mydia playback subtitle check';

String clipPath(String name) => '$e2eClipsDir/$name';

/// mpv's log for the current rig's players, as `prefix: level: text`.
final _mpvLog = <String>[];

typedef _OpenC = Int32 Function(Pointer<Uint8>, Int32, Int32);
typedef _OpenDart = int Function(Pointer<Uint8>, int, int);
typedef _FdC = Int32 Function(Int32);
typedef _FdDart = int Function(int);
typedef _Dup2C = Int32 Function(Int32, Int32);
typedef _Dup2Dart = int Function(int, int);
typedef _MallocC = Pointer<Uint8> Function(IntPtr);
typedef _MallocDart = Pointer<Uint8> Function(int);
typedef _FreeC = Void Function(Pointer<Uint8>);
typedef _FreeDart = void Function(Pointer<Uint8>);

/// File descriptor 2 pointed at a file, through libc (`dart:ffi` alone: the
/// player does not depend on `package:ffi`), until [stop] points it back.
class _StderrCapture {
  _StderrCapture._(this.path, this._saved);

  final String path;
  final int _saved;
  bool _stopped = false;

  static final _libc = DynamicLibrary.process();
  static final _open = _libc.lookupFunction<_OpenC, _OpenDart>('open');
  static final _dup = _libc.lookupFunction<_FdC, _FdDart>('dup');
  static final _close = _libc.lookupFunction<_FdC, _FdDart>('close');
  static final _dup2 = _libc.lookupFunction<_Dup2C, _Dup2Dart>('dup2');
  static final _malloc = _libc.lookupFunction<_MallocC, _MallocDart>('malloc');
  static final _free = _libc.lookupFunction<_FreeC, _FreeDart>('free');

  // Linux's O_WRONLY | O_CREAT | O_TRUNC, and mode 0644.
  static const _flags = 0x1 | 0x40 | 0x200;
  static const _mode = 0x1a4;

  static _StderrCapture start() {
    final path =
        '${Directory.systemTemp.createTempSync('playback_rig').path}'
        '/stderr.log';
    final bytes = [...path.codeUnits, 0];
    final cPath = _malloc(bytes.length);
    cPath.asTypedList(bytes.length).setAll(0, bytes);
    final fd = _open(cPath, _flags, _mode);
    _free(cPath);
    if (fd < 0) fail('could not open $path to capture stderr');
    final saved = _dup(2);
    final redirected = _dup2(fd, 2);
    _close(fd);
    if (saved < 0 || redirected < 0) fail('could not redirect stderr');
    return _StderrCapture._(path, saved);
  }

  String read() => File(path).readAsStringSync();

  /// Points stderr back where it was. Idempotent.
  void stop() {
    if (_stopped) return;
    _stopped = true;
    _dup2(_saved, 2);
    _close(_saved);
  }
}

/// A real player that records when its disposal finished, and mpv's log.
class _RigPlayer extends Player {
  // `info` so the log carries the video output's choices; production's
  // default (`error`) only reports failures.
  _RigPlayer()
    : super(
        configuration: const PlayerConfiguration(logLevel: MPVLogLevel.info),
      ) {
    _logs = stream.log.listen(
      (l) => _mpvLog.add('${l.prefix}: ${l.level}: ${l.text.trimRight()}'),
    );
  }

  late final StreamSubscription<PlayerLog> _logs;
  bool disposed = false;

  NativePlayer get native => platform! as NativePlayer;

  @override
  Future<void> dispose() async {
    await _logs.cancel();
    await super.dispose();
    disposed = true;
  }
}

/// Plays one local file: the path goes to mpv as is.
class _LocalTransport extends FakeTransport {
  _LocalTransport(this.path);
  final String path;

  @override
  Future<PlaybackSource> open(
    PlaybackPlan plan, {
    required String fileId,
    required Duration startAt,
    Duration? totalDuration,
    void Function(LoadingStep step)? onProgress,
  }) async {
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
      durationSeconds: 10,
    ),
    serverRejected: false,
  );

  @override
  Future<StreamingPreparation> prepareStreaming({
    required Object owner,
    required void Function(LoadingStep step) onProgress,
    required bool Function() isCurrent,
  }) async => StreamingReady(
    StreamingSetup(
      memoryKey: 'source:local',
      progress: progress,
      createTransport: ({required bool relayed}) => _transport,
    ),
  );
}

/// The mounted screen and every player it created.
class PlaybackRig {
  PlaybackRig._(this._stderr);

  final _players = <_RigPlayer>[];
  final _StderrCapture? _stderr;

  Player _create() {
    final p = _RigPlayer();
    _players.add(p);
    return p;
  }

  /// The newest player's mpv instance.
  NativePlayer get native {
    expect(_players, isNotEmpty, reason: 'the screen created no player');
    return _players.last.native;
  }

  /// mpv's [name] property on the newest player; empty when unset.
  Future<String> prop(String name) async =>
      (await native.getProperty(name)).trim();

  /// mpv's log since this rig was mounted.
  List<String> get mpvLog => List.unmodifiable(_mpvLog);

  /// The process's native stderr since this rig was mounted, while it is
  /// mounted. Linux only: fails anywhere else.
  String get nativeStderr {
    final capture = _stderr;
    if (capture == null) fail('native stderr is captured on Linux only');
    return capture.read();
  }

  /// Unmounts the screen and waits for every player it made to be disposed.
  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await waitFor(
      tester,
      'players disposed',
      () => _players.every((p) => p.disposed),
      timeout: const Duration(seconds: 15),
    );
    _stopStderr();
  }

  /// Restores stderr and echoes media_kit's own lines into the test log,
  /// which would otherwise never show them.
  void _stopStderr() {
    final capture = _stderr;
    if (capture == null || capture._stopped) return;
    capture.stop();
    for (final line in capture.read().split('\n')) {
      if (line.startsWith('media_kit:')) debugPrint('[playback_rig] $line');
    }
  }
}

/// Mounts the real `PlayerScreen` playing [clip] from [e2eClipsDir].
Future<PlaybackRig> pumpPlayerScreen(WidgetTester tester, String clip) async {
  _mpvLog.clear();
  final settings = SettingsService(storage: MockAuthStorage());
  final container = buildPlayerScreenContainer(
    server: ScriptedMydiaTransport((request, index) => <String, dynamic>{}),
    connectionState: HarnessLink.p2p(serverNodeAddr: 'test-node'),
    castManager: CapturingCastSessionManager(),
    proxyService: TrackingLocalProxyService(),
    coreSettingsService: settings,
    appVersion: '0.0.0-playback-it',
  );
  addTearDown(container.dispose);
  final rig = PlaybackRig._(Platform.isLinux ? _StderrCapture.start() : null);
  // A test that fails before `close` still gets stderr back.
  addTearDown(rig._stopStderr);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: toastLayerBuilder,
        home: PlayerScreen(
          mediaId: 'movie-1',
          mediaType: 'movie',
          fileId: 'file-1',
          title: 'The Lantern Field',
          session: _LocalSession(clipPath(clip)),
          createPlayer: rig._create,
        ),
      ),
    ),
  );
  await tester.pump();
  await waitFor(tester, 'a player for $clip', () => rig._players.isNotEmpty);
  return rig;
}

/// Pumps real frames until [condition] holds; fails after [timeout] with
/// [what] and the tail of mpv's log.
Future<void> waitFor(
  WidgetTester tester,
  String what,
  FutureOr<bool> Function() condition, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) {
      final tail = _mpvLog.length > 20
          ? _mpvLog.sublist(_mpvLog.length - 20)
          : _mpvLog;
      fail(
        'timed out after $timeout waiting for $what; last mpv log lines:\n'
        '${tail.join('\n')}',
      );
    }
    await tester.pump(const Duration(milliseconds: 100));
  }
}
