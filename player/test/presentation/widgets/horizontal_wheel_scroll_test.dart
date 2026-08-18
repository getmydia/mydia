// Contract tests for the wheel-to-horizontal wrapper. Each test pumps the
// arrangement every real call site lives in: a vertically scrolling page with
// a horizontal rail inside it. The two positions are read off the live
// Scrollables rather than off controllers, so tests cover the case where the
// wrapper owns the controller itself.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/widgets/horizontal_wheel_scroll.dart';

const _railHeight = 120.0;
const _cardWidth = 100.0;

Widget _host({
  required ScrollController pageController,
  ScrollController? railController,
  int cards = 40,
  ScrollPhysics? railPhysics,
  TextDirection textDirection = TextDirection.ltr,
}) {
  return Directionality(
    textDirection: textDirection,
    child: MediaQuery(
      data: const MediaQueryData(size: Size(400, 600)),
      child: Material(
        child: ListView(
          controller: pageController,
          children: [
            SizedBox(
              height: _railHeight,
              child: HorizontalWheelScroll(
                controller: railController,
                builder: (context, controller) => ListView.builder(
                  controller: controller,
                  scrollDirection: Axis.horizontal,
                  physics: railPhysics,
                  itemCount: cards,
                  itemBuilder: (context, i) => SizedBox(
                    width: _cardWidth,
                    child: Text('card $i'),
                  ),
                ),
              ),
            ),
            for (int i = 0; i < 10; i++)
              const SizedBox(height: 200, child: Text('spacer')),
          ],
        ),
      ),
    ),
  );
}

ScrollPosition _positionOn(WidgetTester tester, Axis axis) {
  return tester
      .stateList<ScrollableState>(find.byType(Scrollable))
      .map((s) => s.position)
      .firstWhere((p) => p.axis == axis);
}

ScrollPosition _rail(WidgetTester tester) =>
    _positionOn(tester, Axis.horizontal);

ScrollPosition _page(WidgetTester tester) => _positionOn(tester, Axis.vertical);

/// Sends one wheel tick with the pointer parked over the rail.
///
/// Targets the wrapper rather than a card. The wrapper's box moves with the
/// page but not with the rail, so it stays under the pointer across ticks; a
/// card the finder located on one tick has glided out from under the pointer
/// by the next one, and that wheel event would hit nothing.
Future<void> _wheelOverRail(WidgetTester tester, double dy) async {
  final pointer = TestPointer(1, PointerDeviceKind.mouse);
  pointer.hover(tester.getCenter(find.byType(HorizontalWheelScroll)));
  await tester.sendEventToBinding(pointer.scroll(Offset(0, dy)));
  await tester.pump();
}

void main() {
  testWidgets('a vertical wheel scrolls an overflowing rail', (tester) async {
    final page = ScrollController();
    addTearDown(page.dispose);

    await tester.pumpWidget(_host(pageController: page));

    await _wheelOverRail(tester, 120);
    await tester.pumpAndSettle();

    expect(_rail(tester).pixels, greaterThan(0));
    expect(_page(tester).pixels, 0,
        reason: 'the rail claimed the event, so the page must not move');
  });

  testWidgets('the rail glides rather than jumping', (tester) async {
    final page = ScrollController();
    addTearDown(page.dispose);

    await tester.pumpWidget(_host(pageController: page));

    await _wheelOverRail(tester, 120);
    // One frame in, an animation is partway there; a jumpTo would already be
    // at its destination.
    await tester.pump(const Duration(milliseconds: 40));
    final midway = _rail(tester).pixels;

    await tester.pumpAndSettle();

    expect(midway, greaterThan(0));
    expect(midway, lessThan(_rail(tester).pixels));
  });

  testWidgets('consecutive ticks accumulate instead of restarting',
      (tester) async {
    final page = ScrollController();
    addTearDown(page.dispose);

    await tester.pumpWidget(_host(pageController: page));

    await _wheelOverRail(tester, 120);
    await tester.pump(const Duration(milliseconds: 30));
    await _wheelOverRail(tester, 120);
    await tester.pumpAndSettle();

    expect(_rail(tester).pixels, 240,
        reason: 'the second tick must build on the first target, not on '
            'wherever the animation happened to be');
  });

  testWidgets('the wrapper owns a controller when none is given',
      (tester) async {
    final page = ScrollController();
    addTearDown(page.dispose);

    await tester.pumpWidget(_host(pageController: page, railController: null));

    await _wheelOverRail(tester, 120);
    await tester.pumpAndSettle();

    expect(_rail(tester).pixels, greaterThan(0));
  });

  testWidgets('a caller-owned controller drives the same rail', (tester) async {
    final page = ScrollController();
    final rail = ScrollController();
    addTearDown(page.dispose);
    addTearDown(rail.dispose);

    await tester.pumpWidget(
      _host(pageController: page, railController: rail),
    );

    await _wheelOverRail(tester, 120);
    await tester.pumpAndSettle();

    expect(rail.offset, greaterThan(0));
    expect(rail.offset, _rail(tester).pixels);
  });
}
