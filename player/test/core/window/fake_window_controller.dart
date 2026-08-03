import 'dart:ui';

import 'package:player/core/window/window_controller.dart';

/// An in-memory stand-in for the real window, so every branch of the
/// controller and the sizer is testable with no Flutter binding.
class FakeWindowController implements WindowController {
  Rect bounds;
  bool maximized;
  bool fullScreen;
  Size? minimumSize;

  /// Every rect passed to [setBounds], in order.
  final List<Rect> setBoundsCalls = [];

  int maximizeCalls = 0;

  /// When set, [setBounds] throws this instead of recording the call. Lets a
  /// test drive the failure path of code that must still clean up afterwards.
  Object? setBoundsError;

  /// Ordered log of mutating calls, so tests can assert call *sequence*, not
  /// just call counts. `setBoundsCalls`/`maximizeCalls` record what and how
  /// many; this records when relative to each other.
  final List<String> callLog = [];

  FakeWindowController({
    this.bounds = const Rect.fromLTWH(0, 0, 1280, 800),
    this.maximized = false,
    this.fullScreen = false,
  });

  @override
  Future<Rect> getBounds() async => bounds;

  @override
  Future<void> setBounds(Rect newBounds) async {
    final error = setBoundsError;
    if (error != null) throw error;
    setBoundsCalls.add(newBounds);
    callLog.add('setBounds');
    bounds = newBounds;
  }

  @override
  Future<bool> isMaximized() async => maximized;

  @override
  Future<bool> isFullScreen() async => fullScreen;

  @override
  Future<void> maximize() async {
    maximizeCalls++;
    callLog.add('maximize');
    maximized = true;
  }

  @override
  Future<void> setMinimumSize(Size size) async {
    minimumSize = size;
    callLog.add('setMinimumSize');
  }
}
