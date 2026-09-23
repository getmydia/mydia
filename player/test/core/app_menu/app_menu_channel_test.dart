import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/app_menu/app_menu_channel.dart';
import 'package:player/core/app_menu/now_playing.dart';
import 'package:player/core/remote/remote_control_intent.dart';
import 'package:player/core/remote/remote_target_controller.dart';
import 'package:player/native/lib.dart';

/// Records what a Dock command reached, with a settable play state.
class _Binding implements RemotePlayerBinding {
  _Binding({required this.playing});

  bool playing;
  final calls = <String>[];

  @override
  Future<void> play() async => calls.add('play');

  @override
  Future<void> pause() async => calls.add('pause');

  @override
  Future<void> stop() async => calls.add('stop');

  @override
  Future<void> seek(Duration to) async => calls.add('seek');

  @override
  Future<void> setVolume(double level) async => calls.add('volume');

  @override
  Future<void> setMuted(bool muted) async => calls.add('muted');

  @override
  Future<void> selectTrack(TrackKind kind, String? id) async =>
      calls.add('track');

  @override
  Future<void> stepEpisode(EpisodeStep step) async =>
      calls.add('episode:${step.name}');

  @override
  FlutterPlaybackSnapshot describe(int sequence) => FlutterPlaybackSnapshot(
        state: playing
            ? FlutterPlaybackState.playing
            : FlutterPlaybackState.paused,
        mediaItemId: 'item-1',
        episodeId: null,
        title: 'The Long Aurora',
        subtitle: null,
        imageUrl: null,
        positionMs: BigInt.zero,
        durationMs: BigInt.from(5400000),
        volume: 1.0,
        muted: false,
        audioTracks: const [],
        subtitleTracks: const [],
        selectedAudio: null,
        selectedSubtitle: null,
        capabilities: const FlutterTargetCapabilities(
          volume: true,
          trackSelection: true,
          nextPrevious: true,
        ),
        sequence: BigInt.from(sequence),
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<String> routes;
  late int backs;
  late RemoteTargetController remote;
  late NowPlaying? published;
  late AppMenuCommands commands;

  setUp(() {
    routes = [];
    backs = 0;
    remote = RemoteTargetController();
    published = null;
    commands = AppMenuCommands(
      go: routes.add,
      back: () => backs++,
      remote: remote,
      nowPlaying: () => published,
    );
  });

  tearDown(() => remote.dispose());

  /// Lets `RemoteTargetController`'s unawaited dispatch run.
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test('navigate goes to the route', () async {
    await commands.handle(const MethodCall('navigate', '/downloads'));

    expect(routes, ['/downloads']);
  });

  test('a navigate without an absolute route is dropped', () async {
    await commands.handle(const MethodCall('navigate', 'downloads'));
    await commands.handle(const MethodCall('navigate', 42));

    expect(routes, isEmpty);
  });

  test('back pops', () async {
    await commands.handle(const MethodCall('back'));

    expect(backs, 1);
  });

  test('togglePlayPause pauses when the Dock label shows Pause', () async {
    final binding = _Binding(playing: true);
    remote.attachPlayer(binding);
    published = const NowPlaying(
      title: 'The Long Aurora',
      isPlaying: true,
      hasNext: false,
    );

    await commands.handle(const MethodCall('togglePlayPause'));
    await settle();

    expect(binding.calls, ['pause']);
  });

  test('togglePlayPause plays when the Dock label shows Play', () async {
    final binding = _Binding(playing: false);
    remote.attachPlayer(binding);
    published = const NowPlaying(
      title: 'The Long Aurora',
      isPlaying: false,
      hasNext: false,
    );

    await commands.handle(const MethodCall('togglePlayPause'));
    await settle();

    expect(binding.calls, ['play']);
  });

  test(
      'togglePlayPause pauses a buffering player when the Dock label still '
      'shows Pause', () async {
    // The snapshot's playback state is not `playing` here (this is what a
    // buffering player looks like), but the Dock label the host is showing
    // says isPlaying. The toggle must act on the label, not the snapshot, or
    // "Pause" is silently a no-op while buffering.
    final binding = _Binding(playing: false);
    remote.attachPlayer(binding);
    published = const NowPlaying(
      title: 'The Long Aurora',
      isPlaying: true,
      hasNext: false,
    );

    await commands.handle(const MethodCall('togglePlayPause'));
    await settle();

    expect(binding.calls, ['pause']);
  });

  test('nextEpisode steps forward', () async {
    final binding = _Binding(playing: true);
    remote.attachPlayer(binding);

    await commands.handle(const MethodCall('nextEpisode'));
    await settle();

    expect(binding.calls, ['episode:next']);
  });

  test('playback commands with no player attached do nothing', () async {
    published = null;
    await expectLater(
      commands.handle(const MethodCall('togglePlayPause')),
      completes,
    );
    await expectLater(
      commands.handle(const MethodCall('nextEpisode')),
      completes,
    );
  });

  test('an unknown method is reported as not implemented', () async {
    await expectLater(
      commands.handle(const MethodCall('reticulateSplines')),
      throwsA(isA<MissingPluginException>()),
    );
  });

  test('attach routes host calls to handle', () async {
    commands.attach();
    addTearDown(commands.detach);

    // What the host sending `navigate` looks like from Dart's side.
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      kAppMenuChannel.name,
      const StandardMethodCodec()
          .encodeMethodCall(const MethodCall('navigate', '/search')),
      (_) {},
    );

    expect(routes, ['/search']);
  });
}
