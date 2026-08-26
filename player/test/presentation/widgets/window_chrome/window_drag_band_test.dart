import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/widgets/window_chrome/window_drag_band.dart';

import '../../../core/window/fake_window_controller.dart';

Future<void> _pump(
  WidgetTester tester, {
  required FakeWindowController window,
  ValueListenable<bool>? maximized,
}) {
  return tester.pumpWidget(
    MaterialApp(
      home: Align(
        alignment: Alignment.topCenter,
        child: WindowDragBand(
          controller: window,
          height: 36,
          maximized: maximized,
        ),
      ),
    ),
  );
}

void main() {
  group('WindowDragBand', () {
    testWidgets('a drag on the band starts an OS window drag', (tester) async {
      final window = FakeWindowController();
      await _pump(tester, window: window);

      await tester.timedDrag(
        find.byType(WindowDragBand),
        const Offset(40, 0),
        const Duration(milliseconds: 100),
      );
      await tester.pump();

      expect(window.startDraggingCalls, 1);
    });

    testWidgets('a double-tap maximizes a restored window', (tester) async {
      final window = FakeWindowController();
      await _pump(
        tester,
        window: window,
        maximized: ValueNotifier(false),
      );

      final centre = tester.getCenter(find.byType(WindowDragBand));
      await tester.tapAt(centre);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(centre);
      await tester.pump(kDoubleTapTimeout);

      expect(window.maximizeCalls, 1);
      expect(window.unmaximizeCalls, 0);
    });

    testWidgets('a double-tap restores a maximized window', (tester) async {
      final window = FakeWindowController();
      await _pump(
        tester,
        window: window,
        maximized: ValueNotifier(true),
      );

      final centre = tester.getCenter(find.byType(WindowDragBand));
      await tester.tapAt(centre);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(centre);
      await tester.pump(kDoubleTapTimeout);

      expect(window.unmaximizeCalls, 1);
      expect(window.maximizeCalls, 0);
    });

    testWidgets('is exactly as tall as asked', (tester) async {
      await _pump(tester, window: FakeWindowController());

      expect(tester.getSize(find.byType(WindowDragBand)).height, 36);
    });

    testWidgets('paints nothing, so content shows through', (tester) async {
      await _pump(tester, window: FakeWindowController());

      final material = tester.widgetList<Material>(
        find.descendant(
          of: find.byType(WindowDragBand),
          matching: find.byType(Material),
        ),
      );
      expect(material, isEmpty);
    });
  });
}
