import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/player/window_drag_service.dart';

void main() {
  // Under `flutter test` there is no plugin registrant, so every
  // `window_manager` call throws MissingPluginException. Both entry points
  // must swallow that. `initWindowDrag` is called from `_startApp`, which
  // documents an invariant that nothing after
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
