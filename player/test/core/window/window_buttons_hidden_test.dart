import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/window/window_buttons_hidden.dart';

void main() {
  group('windowButtonsHidden', () {
    tearDown(() => windowButtonsHiddenSignal.value = false);

    test('starts visible, which is the state every unmodified window has', () {
      expect(windowButtonsHidden.value, isFalse);
    });

    test('the read-only view reflects writes to the signal', () {
      windowButtonsHiddenSignal.value = true;
      expect(windowButtonsHidden.value, isTrue);
    });

    test('notifies listeners on a change', () {
      var notifications = 0;
      void listener() => notifications++;
      windowButtonsHidden.addListener(listener);
      addTearDown(() => windowButtonsHidden.removeListener(listener));

      windowButtonsHiddenSignal.value = true;
      expect(notifications, 1);

      windowButtonsHiddenSignal.value = true;
      expect(notifications, 1, reason: 'an equal write must not notify');
    });
  });
}
