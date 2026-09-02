import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/remote/node_registration_service.dart';
import 'package:player/core/remote/registration_status.dart';

/// Collects every delay the service asks for instead of sleeping, so a test
/// covering six backoff steps runs in microseconds rather than two minutes.
class FakeDelay {
  final List<Duration> waits = [];

  Future<void> call(Duration duration) async {
    waits.add(duration);
  }
}

/// A delay that never resolves on its own, so a test can hold the service in
/// a backoff wait indefinitely and observe whether something else -- namely
/// [NodeRegistrationService.retryNow] -- is what actually moves it along.
class ControllableDelay {
  final List<Duration> waits = [];

  Future<void> call(Duration duration) {
    waits.add(duration);
    return Completer<void>().future;
  }
}

void main() {
  final clock = DateTime(2026, 9, 1, 12);

  NodeRegistrationService serviceWith(
    RegisterNode register, {
    FakeDelay? delay,
  }) =>
      NodeRegistrationService(
        register: register,
        now: () => clock,
        delay: (delay ?? FakeDelay()).call,
      );

  group('NodeRegistrationService', () {
    test('waits rather than failing when the node id is missing', () async {
      final service = serviceWith((_) async => true);
      addTearDown(service.dispose);

      service.update(controllable: true, nodeId: null, clientReady: true);
      await pumpEventQueue();

      expect(service.status, isA<RegistrationWaiting>());
      expect((service.status as RegistrationWaiting).dependency,
          'this device to come online');
    });

    test('waits rather than failing when the client is not ready', () async {
      final service = serviceWith((_) async => true);
      addTearDown(service.dispose);

      service.update(controllable: true, nodeId: 'abc', clientReady: false);
      await pumpEventQueue();

      expect(service.status, isA<RegistrationWaiting>());
      expect((service.status as RegistrationWaiting).dependency,
          'a server connection');
    });

    test('registers once every input has arrived', () async {
      final sent = <String>[];
      final service = serviceWith((nodeId) async {
        sent.add(nodeId);
        return true;
      });
      addTearDown(service.dispose);

      service.update(controllable: true, nodeId: null, clientReady: false);
      await pumpEventQueue();
      service.update(controllable: true, nodeId: 'abc', clientReady: true);
      await pumpEventQueue();

      expect(sent, ['abc']);
      expect(service.status, isA<RegistrationSucceeded>());
    });

    test('does not re-register a node id the server already holds', () async {
      var calls = 0;
      final service = serviceWith((_) async {
        calls += 1;
        return true;
      });
      addTearDown(service.dispose);

      service.update(controllable: true, nodeId: 'abc', clientReady: true);
      await pumpEventQueue();
      service.update(controllable: true, nodeId: 'abc', clientReady: true);
      await pumpEventQueue();

      expect(calls, 1);
    });

    test('retries with growing backoff until it succeeds', () async {
      final delay = FakeDelay();
      var calls = 0;
      final service = serviceWith(
        (_) async {
          calls += 1;
          return calls >= 3;
        },
        delay: delay,
      );
      addTearDown(service.dispose);

      service.update(controllable: true, nodeId: 'abc', clientReady: true);
      await pumpEventQueue();

      expect(calls, 3);
      expect(delay.waits,
          [const Duration(seconds: 2), const Duration(seconds: 4)]);
      expect(service.status, isA<RegistrationSucceeded>());
    });

    test('retryNow interrupts a pending backoff wait instead of waiting it out',
        () async {
      var calls = 0;
      final delay = ControllableDelay();
      final service = NodeRegistrationService(
        register: (_) async {
          calls += 1;
          // Fails once, then succeeds on the retry retryNow() triggers.
          return calls >= 2;
        },
        now: () => clock,
        delay: delay.call,
      );
      addTearDown(service.dispose);

      service.update(controllable: true, nodeId: 'abc', clientReady: true);
      await pumpEventQueue();

      // The first attempt failed and is now asleep in a backoff wait that
      // this test's ControllableDelay never resolves on its own.
      expect(calls, 1);
      expect(service.status, isA<RegistrationFailed>());
      expect(delay.waits, [const Duration(seconds: 2)]);

      service.retryNow();
      await pumpEventQueue();

      expect(calls, 2,
          reason: 'retryNow must interrupt the backoff wait promptly, not '
              'leave the retry pending until the full delay elapses');
      expect(service.status, isA<RegistrationSucceeded>());
    });

    test('treats a throwing register as a retryable failure', () async {
      var calls = 0;
      final service = serviceWith((_) async {
        calls += 1;
        if (calls == 1) throw StateError('transport down');
        return true;
      });
      addTearDown(service.dispose);

      service.update(controllable: true, nodeId: 'abc', clientReady: true);
      await pumpEventQueue();

      expect(calls, 2);
      expect(service.status, isA<RegistrationSucceeded>());
    });

    test('re-registers the same node id when the client scope changes',
        () async {
      final sent = <String>[];
      final service = serviceWith((nodeId) async {
        sent.add(nodeId);
        return true;
      });
      addTearDown(service.dispose);

      final clientA = Object();
      final clientB = Object();

      service.update(
        controllable: true,
        nodeId: 'abc',
        clientReady: true,
        clientScope: clientA,
      );
      await pumpEventQueue();
      service.update(
        controllable: true,
        nodeId: 'abc',
        clientReady: true,
        clientScope: clientB,
      );
      await pumpEventQueue();

      expect(sent, ['abc', 'abc'],
          reason: 'a different client scope must re-register the same node '
              'id, because a cached confirmation only speaks for the '
              'client that produced it');
    });

    test('re-registers when the node id changes', () async {
      final sent = <String>[];
      final service = serviceWith((nodeId) async {
        sent.add(nodeId);
        return true;
      });
      addTearDown(service.dispose);

      service.update(controllable: true, nodeId: 'abc', clientReady: true);
      await pumpEventQueue();
      service.update(controllable: true, nodeId: 'def', clientReady: true);
      await pumpEventQueue();

      expect(sent, ['abc', 'def']);
    });

    test('goes idle when the device opts out, and resumes when it opts in',
        () async {
      final sent = <String>[];
      final service = serviceWith((nodeId) async {
        sent.add(nodeId);
        return true;
      });
      addTearDown(service.dispose);

      service.update(controllable: false, nodeId: 'abc', clientReady: true);
      await pumpEventQueue();
      expect(service.status, isA<RegistrationIdle>());
      expect(sent, isEmpty);

      service.update(controllable: true, nodeId: 'abc', clientReady: true);
      await pumpEventQueue();
      expect(sent, ['abc']);
    });

    test('replays the current status to a new listener', () async {
      final service = serviceWith((_) async => true);
      addTearDown(service.dispose);

      service.update(controllable: true, nodeId: 'abc', clientReady: true);
      await pumpEventQueue();

      expect(await service.statuses.first, isA<RegistrationSucceeded>());
    });

    test('stops calling register after dispose', () async {
      var calls = 0;
      // Built directly rather than through serviceWith/FakeDelay: this
      // register never succeeds, so without the dispose fix the retry loop
      // runs forever. FakeDelay resolves through microtasks only, with no
      // real Timer, so an unbounded chain of those would starve the event
      // loop and pumpEventQueue (itself Timer-based) would never return,
      // hanging the test before dispose() is even reached. A real
      // zero-duration delay still yields to the event loop each iteration,
      // so the loop can be observed and then actually stopped.
      final service = NodeRegistrationService(
        register: (_) async {
          calls += 1;
          return false;
        },
        now: () => clock,
        delay: (_) => Future<void>.delayed(Duration.zero),
      );

      service.update(controllable: true, nodeId: 'abc', clientReady: true);
      await pumpEventQueue();

      final callsAtDispose = calls;
      expect(callsAtDispose, greaterThan(0));

      service.dispose();
      await pumpEventQueue();
      await pumpEventQueue();

      expect(calls, callsAtDispose,
          reason: 'a disposed service must not keep calling register');

      // Disposing twice must be harmless.
      service.dispose();
    });

    test('delivers later statuses to a continuous listener', () async {
      final service = serviceWith((_) async => true);
      addTearDown(service.dispose);

      final seen = <RegistrationStatus>[];
      final subscription = service.statuses.listen(seen.add);
      addTearDown(subscription.cancel);

      service.update(controllable: true, nodeId: 'abc', clientReady: true);
      await pumpEventQueue();

      expect(seen.last, isA<RegistrationSucceeded>(),
          reason: 'a listener attached before update must see the outcome');
    });
  });
}
