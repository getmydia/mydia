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
    var connected = false;
    final result = waitForPeer(
      nodeId: 'n1',
      isConnected: () => connected,
      connected: events.stream,
      timeout: const Duration(seconds: 10),
    );
    events.add('other');
    // The peer is actually connected by the time its matching event is
    // delivered -- see the disconnected-event tests below for the case
    // where it is not.
    connected = true;
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

  test(
      'a matching event does not succeed the wait while the peer is '
      'reported disconnected', () async {
    final events = StreamController<String>.broadcast();
    var connected = false;
    final result = waitForPeer(
      nodeId: 'n1',
      isConnected: () => connected,
      connected: events.stream,
      timeout: const Duration(milliseconds: 20),
    );

    // The id matches, but the peer service reports it disconnected -- e.g.
    // the peer dropped, or the service reset, between the event being
    // queued and delivered. Must not resolve the wait.
    events.add('n1');

    expect(await result, isFalse);
    await events.close();
  });

  test(
      'succeeds on a later matching event once the peer is actually '
      'connected', () async {
    final events = StreamController<String>.broadcast();
    var connected = false;
    final result = waitForPeer(
      nodeId: 'n1',
      isConnected: () => connected,
      connected: events.stream,
      timeout: const Duration(seconds: 10),
    );

    // Stale event while disconnected: ignored, not a false success.
    events.add('n1');
    await Future<void>.delayed(Duration.zero);

    // The peer is genuinely connected by the time the next matching event
    // arrives.
    connected = true;
    events.add('n1');

    expect(await result, isTrue);
    await events.close();
  });
}
