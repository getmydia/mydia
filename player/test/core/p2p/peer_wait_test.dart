import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/p2p/peer_wait.dart';

void main() {
  test('returns at once when already connected', () async {
    expect(
      await waitForPeer(
        nodeId: 'n1',
        isConnected: () => true,
        connected: const Stream.empty(),
        timeout: const Duration(seconds: 10),
      ),
      isTrue,
    );
  });

  test('returns on the matching connected event, ignoring others', () async {
    final events = StreamController<String>.broadcast();
    final result = waitForPeer(
      nodeId: 'n1',
      isConnected: () => false,
      connected: events.stream,
      timeout: const Duration(seconds: 10),
    );
    events.add('other');
    events.add('n1');
    expect(await result, isTrue);
    // No subscription should outlive a resolved call.
    expect(events.hasListener, isFalse);
    await events.close();
  });

  test('returns false after the timeout', () async {
    expect(
      await waitForPeer(
        nodeId: 'n1',
        isConnected: () => false,
        connected: StreamController<String>.broadcast().stream,
        timeout: const Duration(milliseconds: 20),
      ),
      isFalse,
    );
  });

  test('cancels its stream subscription after a timeout', () async {
    final events = StreamController<String>.broadcast();
    final result = await waitForPeer(
      nodeId: 'n1',
      isConnected: () => false,
      connected: events.stream,
      timeout: const Duration(milliseconds: 20),
    );
    expect(result, isFalse);
    expect(events.hasListener, isFalse);
    await events.close();
  });

  test('reports current connection state when the stream closes', () async {
    final events = StreamController<String>.broadcast();
    var connected = false;
    final result = waitForPeer(
      nodeId: 'n1',
      isConnected: () => connected,
      connected: events.stream,
      timeout: const Duration(seconds: 10),
    );
    connected = true;
    await events.close();
    expect(await result, isTrue);
  });
}
