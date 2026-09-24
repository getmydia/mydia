import 'package:flutter/gestures.dart' show kDoubleTapTimeout;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/layout/window_chrome_inset.dart';
import 'package:player/presentation/widgets/window_chrome/window_drag_band.dart';
import 'package:player/presentation/widgets/window_chrome/window_title_row.dart';

import '../../../core/window/fake_window_controller.dart';
import '../../../helpers/cast_test_overrides.dart';

/// Pumps [child] under a fake desktop window of [width]x800, with
/// [insets] published the way `WindowChromeInset` publishes them for real
/// and `MediaQuery.padding.top` set to what it would have added: the band
/// plus whatever a phone's status bar ([statusBar]) would otherwise
/// contribute.
///
/// `flutter_test`'s default surface is a fixed 800x600, independent of
/// whatever `MediaQueryData` a test nests further down the tree -- nesting
/// only changes what `MediaQuery.of(context)` *reports*, not the real
/// constraints the render tree lays out with. `Breakpoints` reads the
/// former; `Scaffold`'s actual pixel width comes from the latter. A test
/// that only overrode `MediaQueryData` would see [insets]-driven gutters
/// computed against the requested [width] while every widget still had to
/// fit inside the untouched 800-wide default surface, so the two would
/// disagree on where the trailing edge actually is. Resizing the real view
/// keeps them in agreement.
Future<void> _pump(
  WidgetTester tester, {
  required WindowChromeInsets insets,
  double width = 1300,
  double statusBar = 0,
  TextDirection dir = TextDirection.ltr,
  required Widget child,
}) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    ProviderScope(
      overrides: castCapableOverrides(),
      child: MaterialApp(
        home: Directionality(
          textDirection: dir,
          child: MediaQuery(
            data: MediaQueryData(
              size: Size(width, 800),
              padding: EdgeInsets.only(top: statusBar + insets.height),
            ),
            child: WindowChromeInsets.scope(
              insets: insets,
              child: Scaffold(
                body: Align(alignment: Alignment.topCenter, child: child),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

const _mac = WindowChromeInsets(height: 40, leading: 80, trailing: 0);
final _linux = WindowChromeInsets(
    height: 36, leading: 0, trailing: linuxButtonGroupReserve(3));

void main() {
  testWidgets('on macOS the row is the band, starting at the window top',
      (tester) async {
    await _pump(
      tester,
      insets: _mac,
      child: const WindowTitleRow(title: Text('Shelf', key: Key('t'))),
    );
    final row = tester.getRect(find.byType(WindowTitleRow));
    expect(row.top, 0);
    expect(row.height, 40);
    expect(tester.getRect(find.byKey(const Key('t'))).left,
        greaterThanOrEqualTo(80));
  });

  testWidgets('cast sits at the shared end gutter, clear of Linux buttons',
      (tester) async {
    await _pump(
      tester,
      insets: _linux,
      child: const WindowTitleRow(title: Text('Shelf')),
    );
    final cast = tester.getRect(find.byKey(WindowTitleRow.castKey));
    // width 1300 is desktop: getHorizontalPadding 32 - 8 = 24.
    expect(cast.right, 1300 - linuxButtonGroupReserve(3) - 24);
  });

  testWidgets('cast is after every caller action', (tester) async {
    await _pump(
      tester,
      insets: _mac,
      child: const WindowTitleRow(actions: [Icon(Icons.sort, key: Key('a'))]),
    );
    expect(
      tester.getRect(find.byKey(const Key('a'))).right,
      lessThanOrEqualTo(
          tester.getRect(find.byKey(WindowTitleRow.castKey)).left),
    );
  });

  testWidgets('with zero insets it is a toolbar row under the status bar',
      (tester) async {
    await _pump(
      tester,
      insets: WindowChromeInsets.zero,
      width: 400,
      statusBar: 24,
      child: const WindowTitleRow(title: Text('Shelf')),
    );
    final cast = tester.getRect(find.byKey(WindowTitleRow.castKey));
    expect(tester.getRect(find.byType(WindowTitleRow)).height,
        24 + kToolbarHeight);
    expect(cast.right, 400 - 8);
    expect(find.byType(WindowDragBand), findsNothing);
  });

  testWidgets('RTL macOS reserves the lights on the physical left',
      (tester) async {
    await _pump(
      tester,
      insets: const WindowChromeInsets(height: 40, leading: 0, trailing: 80),
      dir: TextDirection.rtl,
      child: const WindowTitleRow(title: Text('Shelf')),
    );
    final cast = tester.getRect(find.byKey(WindowTitleRow.castKey));
    expect(cast.left, greaterThanOrEqualTo(80));
  });

  testWidgets('dragging empty band space drags the window', (tester) async {
    final controller = FakeWindowController();
    await _pump(
      tester,
      insets: _mac,
      child: WindowTitleRow(controller: controller),
    );

    await tester.dragFrom(const Offset(600, 20), const Offset(40, 0));
    // The drag also arms `WindowDragBand`'s double-tap recognizer, which
    // keeps its own timer alive for `kDoubleTapTimeout` waiting for a second
    // tap that never comes. `flutter_test` fails the test if a timer is
    // still pending when it ends, so this drains it before the test exits.
    await tester.pump(kDoubleTapTimeout);

    expect(controller.startDraggingCalls, 1);
  });

  testWidgets('showCast: false draws no cast button', (tester) async {
    await _pump(
      tester,
      insets: _mac,
      child: const WindowTitleRow(showCast: false),
    );
    expect(find.byKey(WindowTitleRow.castKey), findsNothing);
  });
}
