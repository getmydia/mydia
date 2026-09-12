import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/focus/sidebar_focus_boundary.dart';

void main() {
  late FocusNode sidebarNode;
  late FocusNode firstCard;
  late FocusNode secondCard;

  setUp(() {
    sidebarNode = FocusNode(debugLabel: 'sidebar');
    firstCard = FocusNode(debugLabel: 'card-1');
    secondCard = FocusNode(debugLabel: 'card-2');
  });

  tearDown(() {
    sidebarNode.dispose();
    firstCard.dispose();
    secondCard.dispose();
  });

  Future<void> pump(WidgetTester tester, {bool attachSidebar = true}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              if (attachSidebar)
                SizedBox(
                  width: 260,
                  child: Focus(
                    focusNode: sidebarNode,
                    child: const SizedBox(height: 50),
                  ),
                ),
              Expanded(
                child: Column(
                  children: [
                    Focus(
                      focusNode: firstCard,
                      child: const SizedBox(height: 50),
                    ),
                    Focus(
                      focusNode: secondCard,
                      child: const SizedBox(height: 50),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('the trip back returns the card that left, not the first',
      (tester) async {
    await pump(tester);
    final boundary = SidebarFocusBoundary(sidebarNode: sidebarNode);

    secondCard.requestFocus();
    await tester.pump();
    expect(secondCard.hasFocus, isTrue);

    expect(boundary.focusSidebar(), isTrue);
    expect(sidebarNode.hasFocus, isTrue);

    expect(boundary.focusContent(), isTrue);
    // The whole point of recording the origin: card 1 is *also* focusable and
    // sits earlier in traversal order, so an implementation that simply
    // refocused the first card would pass a weaker assertion here.
    expect(secondCard.hasFocus, isTrue);
    expect(firstCard.hasFocus, isFalse);
  });

  testWidgets('an unattached sidebar node reports no move', (tester) async {
    await pump(tester, attachSidebar: false);
    final boundary = SidebarFocusBoundary(sidebarNode: sidebarNode);

    firstCard.requestFocus();
    await tester.pump();

    expect(boundary.focusSidebar(), isFalse);
    expect(firstCard.hasFocus, isTrue, reason: 'focus must not move');
  });

  testWidgets('a remembered card that has left the tree reports no move',
      (tester) async {
    await pump(tester);
    final boundary = SidebarFocusBoundary(sidebarNode: sidebarNode);

    secondCard.requestFocus();
    await tester.pump();
    expect(boundary.focusSidebar(), isTrue);

    // Re-pump without the cards, the way a route change would.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Focus(
            focusNode: sidebarNode,
            child: const SizedBox(height: 50),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(boundary.focusContent(), isFalse);
  });

  testWidgets('a card that returns after a refused move does not steal focus',
      (tester) async {
    await pump(tester);
    final boundary = SidebarFocusBoundary(sidebarNode: sidebarNode);

    secondCard.requestFocus();
    await tester.pump();
    expect(boundary.focusSidebar(), isTrue);

    // Re-pump without the cards, the way a route change would, then ask to
    // return. `focusContent` must return false *without* calling
    // `requestFocus` on the departed node: requestFocus on a parentless node
    // arms `_requestFocusWhenReparented`, so the same card coming back on
    // screen afterwards would take focus uninvited. The returned false is not
    // enough on its own — `_landed` supplies that even when the guard is
    // skipped — so this test reads the side effect instead.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Focus(
            focusNode: sidebarNode,
            child: const SizedBox(height: 50),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(boundary.focusContent(), isFalse);

    // Put the cards back. If `focusContent` had requested focus on the
    // detached node, this re-attachment would honour the deferred request.
    await pump(tester);
    await tester.pump();

    expect(
      FocusManager.instance.primaryFocus,
      isNot(secondCard),
      reason: 'a refused move must not arm the departed card for re-attachment',
    );
  });

  testWidgets('nothing remembered on the first trip', (tester) async {
    await pump(tester);
    final boundary = SidebarFocusBoundary(sidebarNode: sidebarNode);

    expect(boundary.focusContent(), isFalse);
  });
}
