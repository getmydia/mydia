import 'dart:async';
import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/media_session/media_session_state.dart';
import 'package:player/core/media_session/mpris_media_session.dart';
import 'package:player/core/remote/remote_control_intent.dart';

const _root = 'org.mpris.MediaPlayer2';
const _player = 'org.mpris.MediaPlayer2.Player';
final _path = DBusObjectPath('/org/mpris/MediaPlayer2');

const _playing = MediaSessionState(
  status: MediaSessionStatus.playing,
  trackId: 'ep-7',
  title: 'The Lantern Keeper',
  subtitle: 'Harbor Lights · S2E5',
  artworkPath: '/home/u/.var/app/dev.mydia.player/cache/p.jpg',
  duration: Duration(minutes: 60),
  position: Duration(seconds: 10),
  volume: 0.5,
  canSeek: true,
  canGoNext: true,
  canGoPrevious: false,
);

void main() {
  late DBusServer server;
  late DBusAddress address;
  late DBusClient serviceClient;
  late DBusClient testClient;
  late MprisMediaSession session;
  late DBusRemoteObject remote;
  late List<RemoteControlIntent> commands;
  late StreamSubscription<RemoteControlIntent> commandSub;
  var position = const Duration(seconds: 10);
  var clock = DateTime(2026, 9, 24, 20);

  Future<void> settle() async {
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  // A method round trip to the service. The bus delivers a sender's messages
  // in order, so once this reply is back every signal the service emitted
  // before it (and any AddMatch this client sent before it) has landed.
  Future<void> sync() async {
    await remote.getProperty(_root, 'Identity');
    await settle();
  }

  setUp(() async {
    position = const Duration(seconds: 10);
    clock = DateTime(2026, 9, 24, 20);
    server = DBusServer();
    address =
        await server.listenAddress(DBusAddress.unix(dir: Directory.systemTemp));
    serviceClient = DBusClient(address);
    session = (await MprisMediaSession.connect(
      client: serviceClient,
      position: () => position,
      now: () => clock,
      pid: 4242,
    ))!;
    testClient = DBusClient(address);
    remote = DBusRemoteObject(testClient, name: mprisBusName, path: _path);
    commands = [];
    commandSub = session.commands.listen(commands.add);
  });

  tearDown(() async {
    await commandSub.cancel();
    await session.dispose();
    await testClient.close();
    await serviceClient.close();
    await server.close();
  });

  test('owns the primary name and identifies itself', () async {
    expect(session.busName, mprisBusName);
    expect((await remote.getProperty(_root, 'Identity')).asString(),
        'Mydia Player');
    expect((await remote.getProperty(_root, 'DesktopEntry')).asString(),
        'dev.mydia.player');
    expect((await remote.getProperty(_root, 'CanRaise')).asBoolean(), isTrue);
    expect((await remote.getProperty(_root, 'CanQuit')).asBoolean(), isFalse);
  });

  test('starts stopped with no track', () async {
    expect((await remote.getProperty(_player, 'PlaybackStatus')).asString(),
        'Stopped');
    final metadata =
        (await remote.getProperty(_player, 'Metadata')).asStringVariantDict();
    expect(metadata['mpris:trackid'],
        DBusObjectPath('/org/mpris/MediaPlayer2/TrackList/NoTrack'));
  });

  test('reflects a playing episode', () async {
    await session.update(_playing);
    expect((await remote.getProperty(_player, 'PlaybackStatus')).asString(),
        'Playing');
    final metadata =
        (await remote.getProperty(_player, 'Metadata')).asStringVariantDict();
    expect(metadata['mpris:trackid'], DBusObjectPath(mprisTrackPath('ep-7')));
    expect(metadata['xesam:title'], const DBusString('The Lantern Keeper'));
    expect(
        metadata['xesam:artist'], DBusArray.string(['Harbor Lights · S2E5']));
    expect(metadata['mpris:length'], const DBusInt64(3600 * 1000000));
    expect(
        metadata['mpris:artUrl'],
        DBusString(Uri.file('/home/u/.var/app/dev.mydia.player/cache/p.jpg')
            .toString()));
    expect(
        (await remote.getProperty(_player, 'CanGoNext')).asBoolean(), isTrue);
    expect((await remote.getProperty(_player, 'CanGoPrevious')).asBoolean(),
        isFalse);
    expect((await remote.getProperty(_player, 'Volume')).asDouble(), 0.5);
  });

  test('Position is read live', () async {
    await session.update(_playing);
    position = const Duration(seconds: 42);
    expect((await remote.getProperty(_player, 'Position')).asInt64(),
        42 * 1000000);
  });

  test('PropertiesChanged lists only what changed', () async {
    await session.update(_playing);
    final signal = remote.propertiesChanged.first;
    await sync();
    await session.update(MediaSessionState(
      status: MediaSessionStatus.paused,
      trackId: _playing.trackId,
      title: _playing.title,
      subtitle: _playing.subtitle,
      artworkPath: _playing.artworkPath,
      duration: _playing.duration,
      position: _playing.position,
      volume: _playing.volume,
      canSeek: true,
      canGoNext: true,
    ));
    final changed = await signal.timeout(const Duration(seconds: 2));
    expect(changed.propertiesInterface, _player);
    expect(changed.changedProperties.keys, ['PlaybackStatus']);
  });

  test('transport methods become intents', () async {
    await session.update(_playing);
    await remote.callMethod(_player, 'Pause', []);
    await remote.callMethod(_player, 'Play', []);
    await remote.callMethod(_player, 'PlayPause', []);
    await remote.callMethod(_player, 'Stop', []);
    await remote.callMethod(_player, 'Next', []);
    await settle();
    expect(commands.map(_describe), [
      'pause',
      'play',
      'pause', // PlayPause while Playing
      'stop',
      'episode:next',
    ]);
  });

  test('Previous is ignored when unavailable', () async {
    await session.update(_playing);
    await remote.callMethod(_player, 'Previous', []);
    await settle();
    expect(commands, isEmpty);
  });

  test('Seek is relative and clamped to the title', () async {
    await session.update(_playing);
    position = const Duration(seconds: 10);
    await remote.callMethod(_player, 'Seek', [const DBusInt64(-20 * 1000000)]);
    await remote.callMethod(_player, 'Seek', [const DBusInt64(30 * 1000000)]);
    await remote.callMethod(_player, 'Seek', [const DBusInt64(7200 * 1000000)]);
    await settle();
    expect(commands.map(_describe), ['seek:0', 'seek:40', 'seek:3600']);
  });

  test('SetPosition ignores a stale track id and out-of-range positions',
      () async {
    await session.update(_playing);
    await remote.callMethod(_player, 'SetPosition', [
      DBusObjectPath(mprisTrackPath('ep-6')),
      const DBusInt64(5 * 1000000),
    ]);
    await remote.callMethod(_player, 'SetPosition', [
      DBusObjectPath(mprisTrackPath('ep-7')),
      const DBusInt64(7200 * 1000000),
    ]);
    await remote.callMethod(_player, 'SetPosition', [
      DBusObjectPath(mprisTrackPath('ep-7')),
      const DBusInt64(5 * 1000000),
    ]);
    await settle();
    expect(commands.map(_describe), ['seek:5']);
  });

  test('setting Volume becomes a volume intent', () async {
    await session.update(_playing);
    await remote.setProperty(_player, 'Volume', const DBusDouble(0.25));
    await settle();
    expect(commands.map(_describe), ['volume:0.25']);
  });

  test('read-only properties refuse writes', () async {
    expect(
      () => remote.setProperty(_player, 'Rate', const DBusDouble(2.0)),
      throwsA(isA<DBusMethodResponseException>()),
    );
  });

  test('Raise asks for the window', () async {
    final raised = session.raiseRequests.first;
    await remote.callMethod(_root, 'Raise', []);
    await raised.timeout(const Duration(seconds: 2));
  });

  test('a jump emits Seeked, natural progress does not', () async {
    final seeked = <int>[];
    final sub = DBusSignalStream(testClient,
            interface: _player, name: 'Seeked', path: _path)
        .listen((s) => seeked.add(s.values.single.asInt64()));
    await sync();

    await session.update(_playing); // 10s at t0
    clock = clock.add(const Duration(seconds: 5));
    await session.update(_withPosition(const Duration(seconds: 15)));
    await sync();
    expect(seeked, isEmpty);

    clock = clock.add(const Duration(seconds: 1));
    await session.update(_withPosition(const Duration(seconds: 300)));
    await sync();
    expect(seeked, [300 * 1000000]);
    await sub.cancel();
  });

  test('falls back to an instance name when the primary name is taken',
      () async {
    // setUp's session already owns the primary name.
    final second = await MprisMediaSession.connect(
      client: testClient,
      position: () => Duration.zero,
      pid: 999,
    );
    expect(second, isNotNull);
    expect(second!.busName, '$mprisBusName.instance999');
    await second.dispose();
  });

  test('dispose tolerates being called more than once', () async {
    await session.dispose();
    await expectLater(session.dispose(), completes);
  });

  test('track paths are valid object paths', () {
    expect(mprisTrackPath('ep-7'), '/dev/mydia/player/track/ep_7');
    expect(mprisTrackPath(null), '/org/mpris/MediaPlayer2/TrackList/NoTrack');
    expect(() => DBusObjectPath(mprisTrackPath('a.b/c d')), returnsNormally);
  });
}

MediaSessionState _withPosition(Duration position) => MediaSessionState(
      status: _playing.status,
      trackId: _playing.trackId,
      title: _playing.title,
      subtitle: _playing.subtitle,
      artworkPath: _playing.artworkPath,
      duration: _playing.duration,
      position: position,
      volume: _playing.volume,
      canSeek: _playing.canSeek,
      canGoNext: _playing.canGoNext,
      canGoPrevious: _playing.canGoPrevious,
    );

String _describe(RemoteControlIntent intent) => switch (intent) {
      TransportIntent(:final action, :final position) =>
        action == TransportAction.seek
            ? 'seek:${position!.inSeconds}'
            : action.name,
      EpisodeStepIntent(:final step) => 'episode:${step.name}',
      VolumeIntent(:final level) => 'volume:$level',
      _ => intent.toString(),
    };
