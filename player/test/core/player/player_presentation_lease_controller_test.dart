import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/player/player_presentation_lease_controller.dart';

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

const immersive = _SystemUiRequest(SystemUiMode.immersiveSticky, null);

const restored = _SystemUiRequest(
  SystemUiMode.manual,
  SystemUiOverlay.values,
);

/// A system UI request, compared by mode and overlays.
class _SystemUiRequest {
  const _SystemUiRequest(this.mode, this.overlays);

  final SystemUiMode mode;
  final List<SystemUiOverlay>? overlays;

  @override
  bool operator ==(Object other) =>
      other is _SystemUiRequest &&
      other.mode == mode &&
      listEquals(other.overlays, overlays);

  @override
  int get hashCode => Object.hash(mode, Object.hashAll(overlays ?? const []));

  @override
  String toString() => '_SystemUiRequest($mode, $overlays)';
}

void main() {
  group('PlayerPresentationLeaseController', () {
    test('the first owner hides system UI and requests landscape', () async {
      final harness = _Harness();

      harness.controller.acquire(Object(), lockLandscape: true);
      await pumpEventQueue();

      expect(harness.attempted, <Object>[
        immersive,
        landscape,
      ]);
    });

    test('a tablet owner hides system UI without locking orientation',
        () async {
      final harness = _Harness();
      final owner = Object();

      harness.controller.acquire(owner, lockLandscape: false);
      await pumpEventQueue();

      expect(harness.attempted, <Object>[immersive]);
      harness.attempted.clear();

      harness.controller.release(owner);
      harness.runDeferred();
      await pumpEventQueue();

      expect(harness.attempted, <Object>[restored, normal]);
    });

    test('incoming acquire before outgoing release never restores', () async {
      final harness = _Harness();
      final outgoing = Object();
      final incoming = Object();
      harness.controller.acquire(outgoing, lockLandscape: true);
      await pumpEventQueue();
      harness.attempted.clear();

      harness.controller.acquire(incoming, lockLandscape: true);
      harness.controller.release(outgoing);
      harness.runDeferred();
      await pumpEventQueue();

      expect(harness.attempted, isEmpty);
    });

    test('outgoing release before incoming acquire cancels restore', () async {
      final harness = _Harness();
      final outgoing = Object();
      final incoming = Object();
      harness.controller.acquire(outgoing, lockLandscape: true);
      await pumpEventQueue();
      harness.attempted.clear();

      harness.controller.release(outgoing);
      harness.controller.acquire(incoming, lockLandscape: true);
      harness.runDeferred();
      await pumpEventQueue();

      expect(harness.attempted, <Object>[
        immersive,
        landscape,
      ]);
    });

    test('final release restores system UI and orientations after deferral',
        () async {
      final harness = _Harness();
      final owner = Object();
      harness.controller.acquire(owner, lockLandscape: true);
      await pumpEventQueue();
      harness.attempted.clear();

      harness.controller.release(owner);

      expect(harness.attempted, isEmpty);
      expect(harness.scheduled, hasLength(1));

      harness.runDeferred();
      await pumpEventQueue();

      expect(harness.attempted, <Object>[restored, normal]);
    });

    test('duplicate owner operations cannot restore another owner', () async {
      final harness = _Harness();
      final first = Object();
      final second = Object();

      harness.controller.acquire(first, lockLandscape: true);
      harness.controller.acquire(first, lockLandscape: true);
      harness.controller.acquire(second, lockLandscape: true);
      await pumpEventQueue();

      expect(harness.attempted, <Object>[
        immersive,
        landscape,
      ]);
      harness.attempted.clear();

      harness.controller.release(first);
      harness.controller.release(first);
      harness.runDeferred();
      await pumpEventQueue();

      expect(harness.attempted, isEmpty);

      harness.controller.release(second);
      harness.runDeferred();
      await pumpEventQueue();

      expect(harness.attempted, <Object>[restored, normal]);
    });

    test('a slow enter still lands before the restore', () async {
      final gate = Completer<void>();
      final harness = _Harness()..gate = gate;
      final owner = Object();

      harness.controller.acquire(owner, lockLandscape: true);
      harness.controller.release(owner);
      harness.runDeferred();
      await pumpEventQueue();

      expect(harness.attempted, <Object>[immersive]);

      gate.complete();
      await pumpEventQueue();

      expect(harness.attempted, <Object>[
        immersive,
        landscape,
        restored,
        normal,
      ]);
    });

    test('a failed request does not poison the serialized queue', () async {
      final harness = _Harness()..failuresRemaining = 1;
      final reported = <FlutterErrorDetails>[];
      final previousHandler = FlutterError.onError;
      FlutterError.onError = reported.add;
      addTearDown(() => FlutterError.onError = previousHandler);
      final owner = Object();

      harness.controller.acquire(owner, lockLandscape: true);
      await pumpEventQueue();
      harness.controller.release(owner);
      harness.runDeferred();
      await pumpEventQueue();

      expect(reported, hasLength(1));
      expect(harness.attempted, <Object>[
        immersive,
        landscape,
        restored,
        normal,
      ]);
    });
  });
}

/// Records every platform request, system UI modes and orientation lists in
/// one sequence, so ordering between the two is asserted too.
class _Harness {
  final attempted = <Object>[];
  final scheduled = <VoidCallback>[];
  int failuresRemaining = 0;

  /// When set, the first request waits on it, to prove the queue serialises.
  Completer<void>? gate;

  Future<void> _record(Object request) async {
    attempted.add(request);
    final pending = gate;
    if (pending != null) {
      gate = null;
      await pending.future;
    }
    if (failuresRemaining > 0) {
      failuresRemaining--;
      throw StateError('presentation request failed');
    }
  }

  late final PlayerPresentationLeaseController controller =
      PlayerPresentationLeaseController(
    orientationApplier: (orientations) =>
        _record(List<DeviceOrientation>.of(orientations)),
    systemUiModeApplier: (mode, {overlays}) =>
        _record(_SystemUiRequest(mode, overlays)),
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
