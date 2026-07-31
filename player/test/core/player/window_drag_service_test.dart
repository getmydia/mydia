import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/player/window_drag_service.dart';

void main() {
  // Under `flutter test` there is no `runApp`, so no Flutter binding ever
  // exists in this file's isolate. `window_manager`'s lazily-constructed
  // `WindowManager._()` singleton calls `setMethodCallHandler` before a
  // binding exists, which throws synchronously — and since a failed lazy
  // top-level initializer retries on every subsequent access, both tests
  // below hit it independently, not just the first one to touch
  // `windowManager`. Both entry points must swallow that. `initWindowDrag` is
  // called from `_startApp`, which documents an invariant that nothing after
  // `WidgetsFlutterBinding.ensureInitialized()` may throw its way out, on
  // pain of a permanently black window.
  group('window drag service', () {
    test('initWindowDrag completes without throwing', () async {
      await expectLater(initWindowDrag(), completes);
    });

    test('startWindowDrag does not throw', () {
      expect(startWindowDrag, returnsNormally);
    });
  });
}
