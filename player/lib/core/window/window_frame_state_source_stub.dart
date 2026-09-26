import 'package:flutter/foundation.dart';

import 'window_frame_state.dart';

/// No-op on web: there is no GTK window. Holds the floating state forever so
/// callers can read `state.value` unconditionally. Mirrors
/// `decoration_layout_source_stub.dart`.
class WindowFrameStateSource {
  WindowFrameStateSource();

  final ValueNotifier<WindowFrameState> _state =
      ValueNotifier<WindowFrameState>(WindowFrameState.floating);

  ValueListenable<WindowFrameState> get state => _state;

  Future<void> load() async {}

  void dispose() => _state.dispose();
}
