import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/p2p/p2p_service.dart';
import 'package:player/native/lib.dart';

/// The shape flutter_rust_bridge's `RustStreamSink` gives every native
/// stream: an `async*` body looping over a port that only the Rust side
/// feeds.
Stream<T> _idleNativeStream<T>(StreamController<T> port) async* {
  await for (final event in port.stream) {
    yield event;
  }
}

void main() {
  test('debugAdoptNativeSubscriptions adopts and tears down peerSync stream',
      () async {
    final eventPort = StreamController<String>();
    final controlPort = StreamController<FlutterInboundControlRequest>();
    final peerSyncPort = StreamController<FlutterInboundPeerSyncRequest>();
    addTearDown(eventPort.close);
    addTearDown(controlPort.close);
    addTearDown(peerSyncPort.close);

    final received = <FlutterInboundPeerSyncRequest>[];
    final service = P2pService();
    service.debugAdoptNativeSubscriptions(
      events: _idleNativeStream(eventPort).listen((_) {}),
      control: _idleNativeStream(controlPort).listen((_) {}),
      peerSync: _idleNativeStream(peerSyncPort).listen(received.add),
    );

    // Dispose must tear down peerSync subscription promptly without hanging
    await expectLater(
      service.dispose().timeout(const Duration(seconds: 5)),
      completes,
    );

    // After dispose, new events on peerSyncPort do not reach received list
    peerSyncPort.add(const FlutterInboundPeerSyncRequest(
      peer: 'peer1',
      requestId: 'req1',
      request: FlutterPeerSyncRequest.pair(
        claimCode: '123456',
        deviceName: 'Test Phone',
        platform: 'android',
      ),
    ));
    await pumpEventQueue();

    expect(received, isEmpty);
  });
}
