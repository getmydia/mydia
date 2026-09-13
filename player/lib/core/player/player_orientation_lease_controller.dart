import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

typedef OrientationApplier = Future<void> Function(
  List<DeviceOrientation> orientations,
);
typedef DeferredFrameScheduler = void Function(VoidCallback callback);

class PlayerOrientationLeaseController {
  PlayerOrientationLeaseController({
    OrientationApplier? orientationApplier,
    DeferredFrameScheduler? deferredFrameScheduler,
  })  : _applyOrientations =
            orientationApplier ?? SystemChrome.setPreferredOrientations,
        _defer = deferredFrameScheduler ?? _deferUntilAfterFrame;

  static const _landscapeOrientations = <DeviceOrientation>[
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ];

  static const _normalOrientations = <DeviceOrientation>[
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ];

  final OrientationApplier _applyOrientations;
  final DeferredFrameScheduler _defer;
  final Set<Object> _owners = HashSet<Object>.identity();

  Future<void> _requestTail = Future<void>.value();
  int _restoreGeneration = 0;

  void acquire(Object owner) {
    final hadOwners = _owners.isNotEmpty;
    if (!_owners.add(owner)) return;

    _restoreGeneration++;
    if (!hadOwners) {
      _enqueue(_landscapeOrientations);
    }
  }

  void release(Object owner) {
    if (!_owners.remove(owner) || _owners.isNotEmpty) return;

    final generation = ++_restoreGeneration;
    _defer(() {
      if (generation != _restoreGeneration || _owners.isNotEmpty) return;
      _enqueue(_normalOrientations);
    });
  }

  void _enqueue(List<DeviceOrientation> orientations) {
    _requestTail = _applyAfter(_requestTail, orientations);
  }

  Future<void> _applyAfter(
    Future<void> previous,
    List<DeviceOrientation> orientations,
  ) async {
    await previous;

    try {
      await _applyOrientations(orientations);
    } catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'player orientation',
          context: ErrorDescription(
            'while applying a player orientation request',
          ),
        ),
      );
    }
  }

  static void _deferUntilAfterFrame(VoidCallback callback) {
    WidgetsBinding.instance.addPostFrameCallback((_) => callback());
  }
}

final playerOrientationLeaseController = PlayerOrientationLeaseController();
