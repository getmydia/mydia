/// Native implementation of OS window dragging, backed by `window_manager`.
///
/// `dart.library.io` is also true on iOS and Android, so both entry points
/// gate on [PlatformFeatures.isDesktop] as well. Neither is allowed to
/// throw: [initWindowDrag] runs inside `_startApp`, whose stated invariant
/// is that nothing after `WidgetsFlutterBinding.ensureInitialized()` escapes
/// uncaught, and [startWindowDrag] runs from a pointer handler where an
/// exception would surface as a red screen mid-playback.
library;

import 'package:flutter/foundation.dart';
import 'package:window_manager/window_manager.dart';

import 'platform_features.dart';

Future<void> initWindowDrag() async {
  if (!PlatformFeatures.isDesktop) return;
  try {
    await windowManager.ensureInitialized();
  } catch (e) {
    debugPrint('[WindowDrag] Failed to initialize window manager: $e');
  }
}

void startWindowDrag() {
  if (!PlatformFeatures.isDesktop) return;
  try {
    windowManager.startDragging();
  } catch (e) {
    debugPrint('[WindowDrag] Failed to start window drag: $e');
  }
}
