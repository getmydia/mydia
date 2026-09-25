import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show kDoubleTapTimeout;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/cast/cast_providers.dart';
import 'package:player/core/layout/window_chrome_inset.dart';
import 'package:player/presentation/widgets/cast_device_picker.dart';
import 'package:player/presentation/widgets/window_chrome/window_button.dart';
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
      overrides: [
        ...castCapableOverrides(),
        // The macOS double-tap tests tap the real cast button, which opens
        // the real device picker. Without this, that starts real multicast
        // discovery (mDNS/DLNA), which arms a real ten-second sweep Timer
        // that outlives every test that never lets it fire, and
        // `flutter_test` fails any test that ends with a Timer still
        // pending. Mirrors `cast_device_picker_test.dart`.
        castDiscoveryProvider.overrideWith((ref) => const Stream.empty()),
      ],
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
  test(
      'the Linux button reserve matches the button widget it has to clear, '
      'so the two cannot drift apart', () {
    expect(kLinuxWindowButtonExtent, WindowButtonWidget.size + 4);
  });

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

  testWidgets(
      'on macOS, a pointer-down on empty band space reports it to native '
      'immediately, without waiting on a double-tap gesture', (tester) async {
    final previousPlatform = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final controller = FakeWindowController();
      var calls = 0;
      await _pump(
        tester,
        insets: _mac,
        child: WindowTitleRow(
          controller: controller,
          onBandPointerDown: () => calls++,
        ),
      );

      // Same point the drag test above uses: empty band space, clear of the
      // leading inset and the cast button on the trailing edge. A single
      // down-up is enough: native code, not this widget, decides whether it
      // was part of a double-click worth acting on.
      const point = Offset(600, 20);
      await tester.tapAt(point);
      await tester.pump();

      expect(calls, 1);
      expect(controller.maximizeCalls, 0);
      expect(controller.unmaximizeCalls, 0);
    } finally {
      debugDefaultTargetPlatformOverride = previousPlatform;
    }
  });

  testWidgets(
      'on macOS, a pointer-down on the cast button never reaches the band '
      'underneath it', (tester) async {
    final previousPlatform = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final controller = FakeWindowController();
      var calls = 0;
      await _pump(
        tester,
        insets: _mac,
        child: WindowTitleRow(
          controller: controller,
          onBandPointerDown: () => calls++,
        ),
      );

      final cast = tester.getCenter(find.byKey(WindowTitleRow.castKey));
      await tester.tapAt(cast);
      await tester.pump();

      expect(
        calls,
        0,
        reason: 'the Stack hit-test stops at the cast button, so the band '
            "listener underneath it never sees the button's own down",
      );
      expect(controller.maximizeCalls, 0);
      expect(controller.unmaximizeCalls, 0);

      // The tap opened the real cast device picker (WindowTitleRow wires
      // the button to the live pickCastDevice, not a fake), which starts a
      // real search-timeout Timer and an indeterminate spinner. Pop the
      // route the tap pushed so it does not outlive the test.
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      while (navigator.canPop()) {
        navigator.pop();
      }
      await tester.pumpAndSettle();
    } finally {
      debugDefaultTargetPlatformOverride = previousPlatform;
    }
  });

  testWidgets('showCast: false draws no cast button', (tester) async {
    await _pump(
      tester,
      insets: _mac,
      child: const WindowTitleRow(showCast: false),
    );
    expect(find.byKey(WindowTitleRow.castKey), findsNothing);
  });

  testWidgets(
      'with non-zero insets, a tap on the cast button reaches it instead of '
      'starting a window drag', (tester) async {
    final controller = FakeWindowController();
    await _pump(
      tester,
      insets: _mac,
      child: WindowTitleRow(controller: controller),
    );

    await tester.tap(find.byKey(WindowTitleRow.castKey));
    await tester.pump();

    expect(
      find.byType(CastDevicePickerDialog),
      findsOneWidget,
      reason: 'the tap reached the cast button and opened its picker',
    );
    expect(controller.startDraggingCalls, 0);

    // The tap opened the real cast device picker (WindowTitleRow wires the
    // button to the live pickCastDevice, not a fake), which starts a real
    // search-timeout Timer and an indeterminate spinner. Pop the route it
    // pushed so neither outlives the test, mirroring the double-tap test
    // above.
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    while (navigator.canPop()) {
      navigator.pop();
    }
    await tester.pumpAndSettle();
  });

  group('WindowTitleBar', () {
    test('preferredSize.height matches the given height', () {
      const bar = WindowTitleBar(height: 48);
      expect(bar.preferredSize.height, 48);
    });

    testWidgets('decorate wraps the row', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: castCapableOverrides(),
          child: MaterialApp(
            home: WindowTitleBar(
              height: 40,
              decorate: (row) => ColoredBox(
                key: const Key('decorated'),
                color: Colors.black,
                child: row,
              ),
            ),
          ),
        ),
      );

      expect(
        find.descendant(
          of: find.byKey(const Key('decorated')),
          matching: find.byType(WindowTitleRow),
        ),
        findsOneWidget,
      );
    });
  });

  group('buttons in the band', () {
    Future<void> pumpWithBack(WidgetTester tester, WindowChromeInsets insets) =>
        _pump(
          tester,
          insets: insets,
          child: WindowTitleRow(
            leading: IconButton(
              key: const Key('lead'),
              icon: const Icon(Icons.arrow_back_rounded),
              onPressed: () {},
            ),
            title: const Text('Shelf'),
          ),
        );

    void expectClearOfEdges(
      WidgetTester tester,
      Key key, {
      required double band,
      required double margin,
    }) {
      final rect = tester.getRect(find.byKey(key));
      expect(rect.top, greaterThanOrEqualTo(margin), reason: '$key top');
      expect(rect.bottom, lessThanOrEqualTo(band - margin),
          reason: '$key bottom');
    }

    testWidgets('on macOS back and cast clear the band edges', (tester) async {
      final previousPlatform = debugDefaultTargetPlatformOverride;
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      try {
        await pumpWithBack(tester, _mac);
        expectClearOfEdges(tester, const Key('lead'),
            band: _mac.height, margin: 4);
        expectClearOfEdges(tester, WindowTitleRow.castKey,
            band: _mac.height, margin: 4);
      } finally {
        debugDefaultTargetPlatformOverride = previousPlatform;
      }
    });

    testWidgets('on Linux back and cast sit well inside the band',
        (tester) async {
      final band = WindowChromeInsets(
        height: kLinuxWindowChromeHeight,
        leading: 0,
        trailing: linuxButtonGroupReserve(3),
      );
      final previousPlatform = debugDefaultTargetPlatformOverride;
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      try {
        await pumpWithBack(tester, band);
        expectClearOfEdges(tester, const Key('lead'),
            band: band.height, margin: 6);
        expectClearOfEdges(tester, WindowTitleRow.castKey,
            band: band.height, margin: 6);
      } finally {
        debugDefaultTargetPlatformOverride = previousPlatform;
      }
    });

    testWidgets('without a band the buttons keep their full size',
        (tester) async {
      final previousPlatform = debugDefaultTargetPlatformOverride;
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      try {
        await pumpWithBack(tester, WindowChromeInsets.zero);
        expect(tester.getSize(find.byKey(const Key('lead'))).height, 40);
      } finally {
        debugDefaultTargetPlatformOverride = previousPlatform;
      }
    });
  });
}
