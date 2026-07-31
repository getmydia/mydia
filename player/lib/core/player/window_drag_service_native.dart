/// Native implementation of OS window dragging, backed by `window_manager`.
///
/// `dart.library.io` is also true on iOS and Android, so both entry points
/// gate on [PlatformFeatures.isDesktop] as well. Neither is allowed to
/// throw: [initWindowDrag] runs inside `_startApp`, whose stated invariant
/// is that nothing after `WidgetsFlutterBinding.ensureInitialized()` escapes
/// uncaught, and [startWindowDrag] runs from a pointer handler where an
/// exception would surface as a red screen mid-playback.
///
/// `windowManager.startDragging()` itself is declared `async`, so the drag
/// call proper can never throw synchronously: every failure from the actual
/// platform call lands in the returned `Future`, caught below via
/// `.catchError`. A separate, genuinely synchronous throw is still possible
/// one step earlier, evaluating the `windowManager` getter: it lazily
/// constructs a `WindowManager._()` singleton exactly once per isolate, and
/// that constructor calls `setMethodCallHandler` before any Flutter binding
/// may exist yet, which is an assertion failure, not `MissingPluginException`.
/// In the running app this never fires — `runApp` initializes the binding,
/// and [initWindowDrag] forces (and catches) that first construction earlier
/// in startup — but `window_drag_service_test.dart` calls both entry points
/// from bare `test()`s with no binding ever initialized, so every access to
/// `windowManager` in that file hits it. The outer `try` in [startWindowDrag]
/// exists for that construction step, not for the drag call.
library;

import 'dart:async';

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
    unawaited(
      windowManager.startDragging().catchError(
            (Object e) =>
                debugPrint('[WindowDrag] Failed to start window drag: $e'),
          ),
    );
  } catch (e) {
    debugPrint('[WindowDrag] Failed to start window drag: $e');
  }
}
