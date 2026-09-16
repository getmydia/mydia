import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/p2p/p2p_service.dart';
import 'package:player/native/lib.dart';

/// The shape flutter_rust_bridge's `RustStreamSink` gives every native
/// stream: an `async*` body looping over a port that only the Rust side
/// feeds.
///
/// Cancelling a subscription to an `async*` stream completes only once the
/// body reaches its next `yield`. A host with nothing to report never gets
/// there, so that cancel never completes.
Stream<T> _idleNativeStream<T>(StreamController<T> port) async* {
  await for (final event in port.stream) {
    yield event;
  }
}

void main() {
  test('dispose completes while the native streams are idle', () async {
    final eventPort = StreamController<String>();
    final controlPort = StreamController<FlutterInboundControlRequest>();
    addTearDown(eventPort.close);
    addTearDown(controlPort.close);

    final service = P2pService();
    service.debugAdoptNativeSubscriptions(
      events: _idleNativeStream(eventPort).listen((_) {}),
      control: _idleNativeStream(controlPort).listen((_) {}),
    );

    // Player B's teardown in `integration_test/remote_control_test.dart`
    // awaits this, and hung there until the test's 8-minute timeout.
    await expectLater(
      service.dispose().timeout(const Duration(seconds: 5)),
      completes,
    );
  });

  test('dispose stops native events reaching the service', () async {
    final eventPort = StreamController<String>();
    addTearDown(eventPort.close);

    final received = <String>[];
    final service = P2pService();
    service.debugAdoptNativeSubscriptions(
      events: _idleNativeStream(eventPort).listen(received.add),
    );

    await service.dispose().timeout(const Duration(seconds: 5));
    eventPort.add('relay_connected');
    await pumpEventQueue();

    expect(received, isEmpty);
  });
}
