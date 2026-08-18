// Contract tests for the wheel-to-horizontal wrapper. Each test pumps the
// arrangement every real call site lives in: a vertically scrolling page with
// a horizontal rail inside it. The two positions are read off the live
// Scrollables rather than off controllers, so tests cover the case where the
// wrapper owns the controller itself.

import 'dart:async';

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

/// `skipOffstage: false` because reading a scroll offset must not depend on
/// whether that scrollable is currently on screen. Several tests below assert
/// the rail did NOT move while the page scrolled instead, and a page scroll
/// large enough to carry the rail off the top would otherwise make the rail
/// unfindable and throw `StateError` out of `firstWhere` — a fixture failure
/// wearing the costume of a behavior failure.
ScrollPosition _positionOn(WidgetTester tester, Axis axis) {
  return tester
      .stateList<ScrollableState>(find.byType(Scrollable, skipOffstage: false))
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

  testWidgets('a rail that fits on screen leaves the wheel to the page',
      (tester) async {
    final page = ScrollController();
    addTearDown(page.dispose);

    // Two cards at 100px in a 400px viewport: nothing to scroll.
    await tester.pumpWidget(_host(pageController: page, cards: 2));

    expect(_rail(tester).maxScrollExtent, 0);

    await _wheelOverRail(tester, 120);
    await tester.pumpAndSettle();

    expect(_rail(tester).pixels, 0);
    expect(_page(tester).pixels, greaterThan(0));
  });

  testWidgets('a rail at its end hands the wheel to the page', (tester) async {
    final page = ScrollController();
    final rail = ScrollController();
    addTearDown(page.dispose);
    addTearDown(rail.dispose);

    await tester.pumpWidget(_host(pageController: page, railController: rail));
    rail.jumpTo(rail.position.maxScrollExtent);
    await tester.pump();

    final atEnd = rail.offset;

    await _wheelOverRail(tester, 120);
    await tester.pumpAndSettle();

    expect(rail.offset, atEnd);
    expect(_page(tester).pixels, greaterThan(0));
  });

  testWidgets('a rail at its end still scrolls back the other way',
      (tester) async {
    final page = ScrollController();
    final rail = ScrollController();
    addTearDown(page.dispose);
    addTearDown(rail.dispose);

    await tester.pumpWidget(_host(pageController: page, railController: rail));
    rail.jumpTo(rail.position.maxScrollExtent);
    await tester.pump();

    final atEnd = rail.offset;

    await _wheelOverRail(tester, -120);
    await tester.pumpAndSettle();

    expect(rail.offset, lessThan(atEnd));
    expect(_page(tester).pixels, 0);
  });

  testWidgets('an unscrollable rail leaves the wheel to the page',
      (tester) async {
    final page = ScrollController();
    addTearDown(page.dispose);

    await tester.pumpWidget(_host(
      pageController: page,
      railPhysics: const NeverScrollableScrollPhysics(),
    ));

    await _wheelOverRail(tester, 120);
    await tester.pumpAndSettle();

    expect(_rail(tester).pixels, 0);
    expect(_page(tester).pixels, greaterThan(0));
  });

  testWidgets('a horizontal wheel is left to the rail itself', (tester) async {
    final page = ScrollController();
    addTearDown(page.dispose);

    await tester.pumpWidget(_host(pageController: page));

    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    pointer.hover(tester.getCenter(find.byType(HorizontalWheelScroll)));
    await tester.sendEventToBinding(pointer.scroll(const Offset(30, 0)));
    await tester.pump();

    // Flutter's own handling is instant, so the offset is already exact one
    // frame in. An intercepted event would still be mid-glide here.
    expect(_rail(tester).pixels, 30);
    expect(_page(tester).pixels, 0);
  });

  // The next two tests cover a guarantee this widget relies on but does not
  // implement. Scrollable wraps its viewport in an IgnorePointer while it is
  // scrolling, so a rail inside a moving page cannot receive the wheel at all.
  // That is what stops a page scroll from being snagged by a rail it passes
  // over, and it is why this widget carries no momentum lock of its own. If
  // Flutter ever changes it, these fail and the widget needs the clause back.

  testWidgets('a moving page keeps the wheel from reaching the rail',
      (tester) async {
    final page = ScrollController();
    addTearDown(page.dispose);

    await tester.pumpWidget(_host(pageController: page));

    // Short travel over a long duration on purpose: sampled early, the page has
    // moved only a few pixels, so the rail is still under the pointer.
    unawaited(page.animateTo(
      40,
      duration: const Duration(milliseconds: 600),
      curve: Curves.linear,
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));

    expect(_page(tester).isScrollingNotifier.value, isTrue,
        reason: 'premise guard: the page must actually be in motion');

    await _wheelOverRail(tester, 120);
    await tester.pump(const Duration(milliseconds: 100));

    expect(_rail(tester).pixels, 0,
        reason: 'a flick down the page must not be snagged by a rail it '
            'passes over');

    await tester.pumpAndSettle();
  });

  testWidgets('the wheel reaches the rail again once the page settles',
      (tester) async {
    final page = ScrollController();
    addTearDown(page.dispose);

    await tester.pumpWidget(_host(pageController: page));

    unawaited(page.animateTo(
      40,
      duration: const Duration(milliseconds: 600),
      curve: Curves.linear,
    ));
    await tester.pumpAndSettle();

    expect(_page(tester).isScrollingNotifier.value, isFalse);

    await _wheelOverRail(tester, 120);
    await tester.pumpAndSettle();

    expect(_rail(tester).pixels, greaterThan(0),
        reason: 'the IgnorePointer is transient; a settled page must hand the '
            'rail back its wheel');
  });
}
