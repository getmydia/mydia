import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/window/decoration_layout.dart';
import 'package:player/presentation/widgets/window_chrome/window_button.dart';
import 'package:player/presentation/widgets/window_chrome/window_buttons.dart';

import '../../../core/window/fake_window_controller.dart';

Future<void> _pump(
  WidgetTester tester, {
  required List<WindowButton> buttons,
  required FakeWindowController window,
  ValueListenable<bool>? maximized,
  TextDirection direction = TextDirection.ltr,
}) {
  return tester.pumpWidget(
    MaterialApp(
      home: Directionality(
        textDirection: direction,
        child: Align(
          alignment: Alignment.topRight,
          child: WindowButtons(
            buttons: buttons,
            controller: window,
            maximized: maximized,
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('WindowButtons', () {
    testWidgets('renders one button per entry, in the order given',
        (tester) async {
      await _pump(
        tester,
        buttons: const [
          WindowButton.minimize,
          WindowButton.maximize,
          WindowButton.close,
        ],
        window: FakeWindowController(),
      );

      expect(find.byType(WindowButtonWidget), findsNWidgets(3));
      for (final button in WindowButton.values) {
        expect(find.byKey(WindowButtonWidget.keyFor(button)), findsOneWidget);
      }
    });

    testWidgets('renders nothing for an empty list', (tester) async {
      await _pump(tester, buttons: const [], window: FakeWindowController());

      expect(find.byType(WindowButtonWidget), findsNothing);
    });

    testWidgets('lays buttons out in the order given, left to right under LTR',
        (tester) async {
      await _pump(
        tester,
        buttons: const [WindowButton.minimize, WindowButton.close],
        window: FakeWindowController(),
      );

      final minimize = tester.getCenter(
          find.byKey(WindowButtonWidget.keyFor(WindowButton.minimize)));
      final close = tester
          .getCenter(find.byKey(WindowButtonWidget.keyFor(WindowButton.close)));

      expect(minimize.dx, lessThan(close.dx));
    });

    testWidgets('mirrors under RTL, matching what GTK does', (tester) async {
      await _pump(
        tester,
        buttons: const [WindowButton.minimize, WindowButton.close],
        window: FakeWindowController(),
        direction: TextDirection.rtl,
      );

      final minimize = tester.getCenter(
          find.byKey(WindowButtonWidget.keyFor(WindowButton.minimize)));
      final close = tester
          .getCenter(find.byKey(WindowButtonWidget.keyFor(WindowButton.close)));

      expect(minimize.dx, greaterThan(close.dx));
    });

    testWidgets('minimize calls minimize', (tester) async {
      final window = FakeWindowController();
      await _pump(tester,
          buttons: const [WindowButton.minimize], window: window);

      await tester
          .tap(find.byKey(WindowButtonWidget.keyFor(WindowButton.minimize)));
      await tester.pump();

      expect(window.minimizeCalls, 1);
    });

    testWidgets('close calls close', (tester) async {
      final window = FakeWindowController();
      await _pump(tester, buttons: const [WindowButton.close], window: window);

      await tester
          .tap(find.byKey(WindowButtonWidget.keyFor(WindowButton.close)));
      await tester.pump();

      expect(window.closeCalls, 1);
    });

    testWidgets('maximize calls maximize while restored', (tester) async {
      final window = FakeWindowController();
      await _pump(
        tester,
        buttons: const [WindowButton.maximize],
        window: window,
        maximized: ValueNotifier(false),
      );

      await tester
          .tap(find.byKey(WindowButtonWidget.keyFor(WindowButton.maximize)));
      await tester.pump();

      expect(window.maximizeCalls, 1);
      expect(window.unmaximizeCalls, 0);
    });

    testWidgets('maximize calls unmaximize while maximized', (tester) async {
      final window = FakeWindowController();
      await _pump(
        tester,
        buttons: const [WindowButton.maximize],
        window: window,
        maximized: ValueNotifier(true),
      );

      await tester
          .tap(find.byKey(WindowButtonWidget.keyFor(WindowButton.maximize)));
      await tester.pump();

      expect(window.unmaximizeCalls, 1);
      expect(window.maximizeCalls, 0);
    });

    testWidgets('the maximize glyph swaps when the window maximizes',
        (tester) async {
      final maximized = ValueNotifier(false);
      await _pump(
        tester,
        buttons: const [WindowButton.maximize],
        window: FakeWindowController(),
        maximized: maximized,
      );

      Icon glyph() => tester.widget<Icon>(
            find.descendant(
              of: find.byKey(WindowButtonWidget.keyFor(WindowButton.maximize)),
              matching: find.byType(Icon),
            ),
          );

      final restoredIcon = glyph().icon;

      maximized.value = true;
      await tester.pump();

      expect(glyph().icon, isNot(restoredIcon));
    });
  });
}
