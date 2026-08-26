import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/window/window_controller.dart';

import 'fake_window_controller.dart';

/// The fake is shared test infrastructure for every chrome widget test, so
/// its own bookkeeping is worth pinning: a fake that silently failed to
/// record a call would turn those widget tests green for the wrong reason.
void main() {
  group('FakeWindowController', () {
    test('records minimize', () async {
      final window = FakeWindowController();
      await window.minimize();
      expect(window.minimizeCalls, 1);
      expect(window.callLog, ['minimize']);
    });

    test('records close', () async {
      final window = FakeWindowController();
      await window.close();
      expect(window.closeCalls, 1);
      expect(window.callLog, ['close']);
    });

    test('unmaximize clears the maximized flag maximize sets', () async {
      final window = FakeWindowController();
      await window.maximize();
      expect(await window.isMaximized(), isTrue);

      await window.unmaximize();
      expect(await window.isMaximized(), isFalse);
      expect(window.unmaximizeCalls, 1);
      expect(window.callLog, ['maximize', 'unmaximize']);
    });

    test('records startDragging', () async {
      final window = FakeWindowController();
      await window.startDragging();
      expect(window.startDraggingCalls, 1);
      expect(window.callLog, ['startDragging']);
    });

    test('records every resize edge, in order', () async {
      final window = FakeWindowController();
      await window.startResizing(WindowEdge.topLeft);
      await window.startResizing(WindowEdge.bottom);

      expect(
        window.startResizingCalls,
        [WindowEdge.topLeft, WindowEdge.bottom],
      );
      expect(window.callLog, ['startResizing', 'startResizing']);
    });

    test('WindowEdge covers all eight edges and corners', () {
      expect(WindowEdge.values, hasLength(8));
    });
  });
}
