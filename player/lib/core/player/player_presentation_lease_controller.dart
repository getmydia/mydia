import 'dart:collection';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

typedef OrientationApplier = Future<void> Function(
  List<DeviceOrientation> orientations,
);
typedef SystemUiModeApplier = Future<void> Function(SystemUiMode mode);
typedef DeferredFrameScheduler = void Function(VoidCallback callback);

/// How the device is presented while a player route is open on native mobile:
/// system bars hidden for the whole session, and on phones the display pinned
/// to landscape.
///
/// One lease for the player route's whole lifetime. A route replacement (a
/// different player route, not an episode advance, which reuses the State)
/// hands the lease from the outgoing screen to the incoming one without
/// restoring in between, and the restore is deferred a frame so an acquire in
/// that frame cancels it. Every platform request goes through one serialised
/// queue, so an enter can never land after the restore that follows it.
class PlayerPresentationLeaseController {
  PlayerPresentationLeaseController({
    OrientationApplier? orientationApplier,
    SystemUiModeApplier? systemUiModeApplier,
    DeferredFrameScheduler? deferredFrameScheduler,
  })  : _applyOrientations =
            orientationApplier ?? SystemChrome.setPreferredOrientations,
        _applySystemUiMode =
            systemUiModeApplier ?? SystemChrome.setEnabledSystemUIMode,
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
  final SystemUiModeApplier _applySystemUiMode;
  final DeferredFrameScheduler _defer;
  final Set<Object> _owners = HashSet<Object>.identity();

  Future<void> _requestTail = Future<void>.value();
  int _restoreGeneration = 0;

  /// [lockLandscape] is honoured only for the first owner. A handoff between
  /// a phone-sized and a tablet-sized decision cannot happen on one device.
  void acquire(Object owner, {required bool lockLandscape}) {
    final hadOwners = _owners.isNotEmpty;
    if (!_owners.add(owner)) return;

    _restoreGeneration++;
    if (hadOwners) return;

    _enqueue(() => _applySystemUiMode(SystemUiMode.immersiveSticky));
    if (lockLandscape) {
      _enqueue(() => _applyOrientations(_landscapeOrientations));
    }
  }

  void release(Object owner) {
    if (!_owners.remove(owner) || _owners.isNotEmpty) return;

    final generation = ++_restoreGeneration;
    _defer(() {
      if (generation != _restoreGeneration || _owners.isNotEmpty) return;
      _enqueue(() => _applySystemUiMode(SystemUiMode.edgeToEdge));
      _enqueue(() => _applyOrientations(_normalOrientations));
    });
  }

  void _enqueue(Future<void> Function() request) {
    _requestTail = _applyAfter(_requestTail, request);
  }

  Future<void> _applyAfter(
    Future<void> previous,
    Future<void> Function() request,
  ) async {
    await previous;

    try {
      await request();
    } catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'player presentation',
          context: ErrorDescription(
            'while applying a player presentation request',
          ),
        ),
      );
    }
  }

  static void _deferUntilAfterFrame(VoidCallback callback) {
    WidgetsBinding.instance.addPostFrameCallback((_) => callback());
  }
}

final playerPresentationLeaseController = PlayerPresentationLeaseController();
