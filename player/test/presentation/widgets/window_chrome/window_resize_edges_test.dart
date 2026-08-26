import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/window/window_controller.dart';
import 'package:player/presentation/widgets/window_chrome/window_resize_edges.dart';

import '../../../core/window/fake_window_controller.dart';

void main() {
  /// The window is 800x600 under the default test surface. Each entry is the
  /// offset to press and the edge it must resolve to.
  const cases = <String, (Offset, WindowEdge)>{
    'top': (Offset(400, 2), WindowEdge.top),
    'bottom': (Offset(400, 598), WindowEdge.bottom),
    'left': (Offset(2, 300), WindowEdge.left),
    'right': (Offset(798, 300), WindowEdge.right),
    'topLeft': (Offset(2, 2), WindowEdge.topLeft),
    'topRight': (Offset(798, 2), WindowEdge.topRight),
    'bottomLeft': (Offset(2, 598), WindowEdge.bottomLeft),
    'bottomRight': (Offset(798, 598), WindowEdge.bottomRight),
  };

  Future<FakeWindowController> pump(WidgetTester tester) async {
    final window = FakeWindowController();
    await tester.pumpWidget(
      MaterialApp(
        home: WindowResizeEdges(
          controller: window,
          child: const ColoredBox(color: Color(0xFF000000)),
        ),
      ),
    );
    return window;
  }

  group('WindowResizeEdges', () {
    cases.forEach((name, testCase) {
      final (offset, edge) = testCase;

      testWidgets('a drag at $name resizes from ${edge.name}', (tester) async {
        final window = await pump(tester);

        await tester.timedDragFrom(
          offset,
          const Offset(10, 10),
          const Duration(milliseconds: 100),
        );
        await tester.pump();

        expect(window.startResizingCalls, [edge]);
      });
    });

    testWidgets('all eight edges are covered by the case table',
        (tester) async {
      expect(
        cases.values.map((c) => c.$2).toSet(),
        WindowEdge.values.toSet(),
      );
    });

    testWidgets('a drag in the middle resizes nothing, so content still works',
        (tester) async {
      final window = await pump(tester);

      await tester.timedDragFrom(
        const Offset(400, 300),
        const Offset(10, 10),
        const Duration(milliseconds: 100),
      );
      await tester.pump();

      expect(window.startResizingCalls, isEmpty);
    });

    testWidgets('the child fills the widget, uninset by the edge zones',
        (tester) async {
      await pump(tester);

      expect(
        tester.getSize(find.byType(ColoredBox).first),
        const Size(800, 600),
      );
    });
  });
}
