import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/window/desktop_window.dart';
import 'package:player/core/window/player_window_sizer.dart';

void main() {
  // Under `flutter test` there is no `runApp`, so no Flutter binding ever
  // exists in this file's isolate. `window_manager`'s lazily-constructed
  // `WindowManager._()` singleton calls `setMethodCallHandler` before a
  // binding exists, which throws synchronously — and a failed lazy top-level
  // initializer retries on every subsequent access, so each test below hits it
  // independently, not just the first. Every entry point must swallow that.
  //
  // `initDesktopWindow` is called from `_startApp`, which documents an
  // invariant that nothing after `WidgetsFlutterBinding.ensureInitialized()`
  // may throw its way out, on pain of a permanently black window.
  group('desktop window facade', () {
    test('initDesktopWindow completes without throwing', () async {
      await expectLater(initDesktopWindow(), completes);
    });

    test('startWindowDrag does not throw', () {
      expect(startWindowDrag, returnsNormally);
    });

    test('createPlayerWindowSizer returns a usable sizer', () async {
      // With no window initialized this is the no-op, and its methods must
      // still be safe to call — PlayerScreen calls them unconditionally.
      final sizer = createPlayerWindowSizer();

      expect(sizer, isA<PlayerWindowSizer>());
      await expectLater(sizer.attach(), completes);
      await expectLater(sizer.detach(), completes);
    });
  });
}
