import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/player/player_orientation_lease_controller.dart';

const landscape = <DeviceOrientation>[
  DeviceOrientation.landscapeLeft,
  DeviceOrientation.landscapeRight,
];

const normal = <DeviceOrientation>[
  DeviceOrientation.portraitUp,
  DeviceOrientation.portraitDown,
  DeviceOrientation.landscapeLeft,
  DeviceOrientation.landscapeRight,
];

void main() {
  group('PlayerOrientationLeaseController', () {
    test('the first owner requests landscape', () async {
      final harness = _Harness();

      harness.controller.acquire(Object());
      await pumpEventQueue();

      expect(harness.attempted, <List<DeviceOrientation>>[landscape]);
    });

    test('incoming acquire before outgoing release never restores', () async {
      final harness = _Harness();
      final outgoing = Object();
      final incoming = Object();
      harness.controller.acquire(outgoing);
      await pumpEventQueue();
      harness.attempted.clear();

      harness.controller.acquire(incoming);
      harness.controller.release(outgoing);
      harness.runDeferred();
      await pumpEventQueue();

      expect(harness.attempted, isEmpty);
    });

    test('outgoing release before incoming acquire cancels restore', () async {
      final harness = _Harness();
      final outgoing = Object();
      final incoming = Object();
      harness.controller.acquire(outgoing);
      await pumpEventQueue();
      harness.attempted.clear();

      harness.controller.release(outgoing);
      harness.controller.acquire(incoming);
      harness.runDeferred();
      await pumpEventQueue();

      expect(harness.attempted, <List<DeviceOrientation>>[landscape]);
    });

    test('final release restores normal orientations after deferral', () async {
      final harness = _Harness();
      final owner = Object();
      harness.controller.acquire(owner);
      await pumpEventQueue();
      harness.attempted.clear();

      harness.controller.release(owner);

      expect(harness.attempted, isEmpty);
      expect(harness.scheduled, hasLength(1));

      harness.runDeferred();
      await pumpEventQueue();

      expect(harness.attempted, <List<DeviceOrientation>>[normal]);
    });

    test('duplicate owner operations cannot restore another owner', () async {
      final harness = _Harness();
      final first = Object();
      final second = Object();

      harness.controller.acquire(first);
      harness.controller.acquire(first);
      harness.controller.acquire(second);
      await pumpEventQueue();

      expect(harness.attempted, <List<DeviceOrientation>>[landscape]);
      harness.attempted.clear();

      harness.controller.release(first);
      harness.controller.release(first);
      harness.runDeferred();
      await pumpEventQueue();

      expect(harness.attempted, isEmpty);

      harness.controller.release(second);
      harness.runDeferred();
      await pumpEventQueue();

      expect(harness.attempted, <List<DeviceOrientation>>[normal]);
    });

    test('a failed request does not poison the serialized queue', () async {
      final harness = _Harness()..failuresRemaining = 1;
      final reported = <FlutterErrorDetails>[];
      final previousHandler = FlutterError.onError;
      FlutterError.onError = reported.add;
      addTearDown(() => FlutterError.onError = previousHandler);
      final owner = Object();

      harness.controller.acquire(owner);
      await pumpEventQueue();
      harness.controller.release(owner);
      harness.runDeferred();
      await pumpEventQueue();

      expect(reported, hasLength(1));
      expect(harness.attempted, <List<DeviceOrientation>>[landscape, normal]);
    });
  });
}

class _Harness {
  final attempted = <List<DeviceOrientation>>[];
  final scheduled = <VoidCallback>[];
  int failuresRemaining = 0;

  late final PlayerOrientationLeaseController controller =
      PlayerOrientationLeaseController(
    orientationApplier: (orientations) async {
      attempted.add(List<DeviceOrientation>.of(orientations));
      if (failuresRemaining > 0) {
        failuresRemaining--;
        throw StateError('orientation request failed');
      }
    },
    deferredFrameScheduler: scheduled.add,
  );

  void runDeferred() {
    final callbacks = List<VoidCallback>.of(scheduled);
    scheduled.clear();
    for (final callback in callbacks) {
      callback();
    }
  }
}
