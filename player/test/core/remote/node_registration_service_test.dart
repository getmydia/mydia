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
  });
}
