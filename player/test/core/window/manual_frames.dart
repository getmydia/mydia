import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// Stands in for `SchedulerBinding.addPostFrameCallback`, so tests decide
/// when "the frame" ends instead of needing a binding.
class ManualFrames {
  final List<VoidCallback> _pending = [];

  void schedule(VoidCallback callback) => _pending.add(callback);

  /// Runs every callback scheduled so far, then lets the async work they
  /// start (fake platform calls are microtasks) finish.
  Future<void> end() async {
    final callbacks = List<VoidCallback>.of(_pending);
    _pending.clear();
    for (final callback in callbacks) {
      callback();
    }
    await pumpEventQueue();
  }
}
