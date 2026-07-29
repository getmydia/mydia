import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/cast/cast_backend.dart';
import 'package:player/core/cast/cast_capabilities.dart';
import 'package:player/domain/models/cast_device.dart';

import 'fake_cast_backend.dart';

void main() {
  const device = CastDevice(
    id: 'd1',
    name: 'Living Room',
    protocol: CastProtocolKind.chromecast,
  );

  late FakeCastBackend backend;

  setUp(() => backend = FakeCastBackend());
  tearDown(() => backend.dispose());

  test('emits discovered devices', () async {
    final devices = <List<CastDevice>>[];
    backend
        .startDiscovery(capabilities: const CastCapabilities.full())
        .listen(devices.add);

    backend.emitDevices(const [device]);
    await Future<void>.delayed(Duration.zero);

    expect(devices.single.single.name, 'Living Room');
  });

  test('tracks the connected device', () async {
    expect(backend.connectedDevice, isNull);

    await backend.connect(device);
    expect(backend.connectedDevice, device);

    await backend.disconnect();
    expect(backend.connectedDevice, isNull);
  });

  test('records loaded media requests', () async {
    await backend.connect(device);
    await backend.loadMedia(const CastMediaRequest(
      url: 'http://example.test/a.m3u8',
      kind: CastMediaKind.hls,
      title: 'Movie',
    ));

    expect(backend.loadedRequests.single.url, 'http://example.test/a.m3u8');
    expect(backend.loadedRequests.single.kind, CastMediaKind.hls);
  });

  test('failNextLoad makes the next loadMedia throw a typed failure', () async {
    await backend.connect(device);
    backend.failNextLoad(CastFailureKind.mediaLoadFailed);

    await expectLater(
      backend.loadMedia(const CastMediaRequest(
        url: 'http://example.test/a.m3u8',
        kind: CastMediaKind.hls,
        title: 'Movie',
      )),
      throwsA(isA<CastBackendException>()
          .having((e) => e.kind, 'kind', CastFailureKind.mediaLoadFailed)),
    );
  });

  test('emits playback state and position', () async {
    final states = <CastPlaybackState>[];
    final positions = <Duration>[];
    backend.stateStream.listen(states.add);
    backend.positionStream.listen(positions.add);

    backend.emitState(CastPlaybackState.playing);
    backend.emitPosition(const Duration(seconds: 42));
    await Future<void>.delayed(Duration.zero);

    expect(states, [CastPlaybackState.playing]);
    expect(positions, [const Duration(seconds: 42)]);
  });

  test('emits asynchronous failures', () async {
    final failures = <CastFailureKind>[];
    backend.failureStream.listen(failures.add);

    backend.emitFailure(CastFailureKind.connectionLost);
    await Future<void>.delayed(Duration.zero);

    expect(failures, [CastFailureKind.connectionLost]);
  });
}
