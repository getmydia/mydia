import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/cast/cast_capabilities.dart';
import 'package:player/core/cast/cast_providers.dart';
import 'package:player/core/cast/cast_session_manager.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/domain/models/cast_device.dart';
import 'package:player/presentation/widgets/cast_bar/cast_bar_state.dart';

const _device = CastDevice(
  id: 'd1',
  name: 'Cottage Chromecast',
  protocol: CastProtocolKind.chromecast,
);

const _media = CastMediaInfo(
  title: 'Silo - S02E01',
  duration: Duration(minutes: 50),
  position: Duration(seconds: 29),
);

/// Records play and pause; anything else it is asked fails the test.
class _RecordingManager implements CastSessionManager {
  final calls = <String>[];

  @override
  Future<void> play() async => calls.add('play');

  @override
  Future<void> pause() async => calls.add('pause');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<CastBarState?> _stateFor(CastSession? session) async {
  final container = ProviderContainer(overrides: [
    castCapabilitiesProvider.overrideWithValue(const CastCapabilities.full()),
    hasMydiaProvider.overrideWithValue(true),
    castSessionProvider.overrideWith((ref) => Stream.value(session)),
  ]);
  addTearDown(container.dispose);
  final sub = container.listen(castBarStateProvider, (prev, next) {});
  addTearDown(sub.close);
  await container.read(castSessionProvider.future);
  return container.read(castBarStateProvider);
}

void main() {
  test('connecting', () async {
    final state = await _stateFor(const CastSession(
      device: _device,
      playbackState: CastPlaybackState.idle,
      connectionState: CastConnectionState.connecting,
    ));
    expect(state, isA<CastBarConnecting>());
  });

  test('a stale session with media is stale', () async {
    final state = await _stateFor(const CastSession(
      device: _device,
      mediaInfo: _media,
      playbackState: CastPlaybackState.playing,
      connectionState: CastConnectionState.lost,
    ));
    expect(state, isA<CastBarStale>());
  });

  test('a stale session without media is offline', () async {
    final state = await _stateFor(const CastSession(
      device: _device,
      playbackState: CastPlaybackState.idle,
      connectionState: CastConnectionState.lost,
    ));
    expect((state as CastBarOffline).device, _device);
  });

  test('connected, nothing loaded, is idle', () async {
    final state = await _stateFor(const CastSession(
      device: _device,
      playbackState: CastPlaybackState.idle,
    ));
    expect(state, isA<CastBarIdle>());
  });

  test('connected with media is playing', () async {
    final state = await _stateFor(const CastSession(
      device: _device,
      mediaInfo: _media,
      playbackState: CastPlaybackState.playing,
    ));
    expect(state, isA<CastBarPlaying>());
  });

  test('no Mydia server: nothing', () async {
    final container = ProviderContainer(overrides: [
      castCapabilitiesProvider.overrideWithValue(const CastCapabilities.full()),
      hasMydiaProvider.overrideWithValue(false),
    ]);
    addTearDown(container.dispose);
    expect(container.read(castBarStateProvider), isNull);
  });

  group('toggleCastPlayback', () {
    test('pauses while playing, plays while paused', () async {
      final manager = _RecordingManager();
      await toggleCastPlayback(
        manager,
        const CastSession(
            device: _device,
            mediaInfo: _media,
            playbackState: CastPlaybackState.playing),
      );
      await toggleCastPlayback(
        manager,
        const CastSession(
            device: _device,
            mediaInfo: _media,
            playbackState: CastPlaybackState.paused),
      );
      expect(manager.calls, ['pause', 'play']);
    });

    test('does nothing while syncing', () async {
      final manager = _RecordingManager();
      await toggleCastPlayback(
        manager,
        const CastSession(
          device: _device,
          mediaInfo: _media,
          playbackState: CastPlaybackState.playing,
          isSyncing: true,
        ),
      );
      expect(manager.calls, isEmpty);
    });
  });

  test('CastBarText matches what the bar has always said', () {
    expect(CastBarText.idleTitle('Den'), 'Ready to play on Den');
    expect(CastBarText.idleStatus, 'Connected');
    expect(CastBarText.connectingTitle('Den'), 'Connecting to Den…');
    expect(CastBarText.offlineStatus, 'Not connected');
    expect(CastBarText.staleStatus('Den'), 'Lost connection to Den');
    expect(CastBarText.ambientStatus('Den'), 'Playing on Den');
    expect(CastBarText.playingStatus('Den', syncing: false), 'Casting to Den');
    expect(CastBarText.playingStatus('Den', syncing: true),
        'Reconnecting to Den…');
  });
}
