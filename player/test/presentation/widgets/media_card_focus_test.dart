// MediaCard is the single widget a D-pad viewer spends most of their time on:
// every rail and every grid is made of them. Before this it was a MouseRegion
// wrapping a GestureDetector, with no focus node, no keyboard activation and
// no ring, so a remote could neither reach it nor show where it was.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/widgets/focus_highlight.dart';
import 'package:player/presentation/widgets/media_card.dart';

// ProviderScope is required: PosterFrame, which MediaCard composes, is a
// ConsumerStatefulWidget and reads a provider in initState.
Widget _host(Widget child) => ProviderScope(
      child: MaterialApp(
        home: Scaffold(body: Center(child: child)),
      ),
    );

void main() {
  testWidgets('is reachable by focus traversal', (tester) async {
    await tester.pumpWidget(
      _host(
        MediaCard(
          title: 'Blade Runner',
          action: MediaCardAction.open,
          onTap: () {},
        ),
      ),
    );

    final node = tester.widget<FocusableActionDetector>(
      find.byType(FocusableActionDetector).first,
    );
    expect(node.enabled, isTrue);
  });

  testWidgets('paints a ring when focused', (tester) async {
    await tester.pumpWidget(
      _host(
        MediaCard(
          title: 'Blade Runner',
          action: MediaCardAction.open,
          onTap: () {},
        ),
      ),
    );

    // Drive focus the way traversal does, rather than reaching into state.
    final scope = FocusScope.of(tester.element(find.byType(MediaCard)));
    scope.nextFocus();
    await tester.pump();

    final decorated = tester.widget<DecoratedBox>(
      find.byKey(FocusHighlight.ringKey),
    );
    expect((decorated.decoration as BoxDecoration).border, isNotNull);
  });

  testWidgets('Enter activates the same callback a tap does', (tester) async {
    var taps = 0;

    await tester.pumpWidget(
      _host(
        MediaCard(
          title: 'Blade Runner',
          action: MediaCardAction.open,
          onTap: () => taps++,
        ),
      ),
    );

    final scope = FocusScope.of(tester.element(find.byType(MediaCard)));
    scope.nextFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(taps, 1);
  });

  testWidgets('a card with no onTap is not a focus stop', (tester) async {
    await tester.pumpWidget(
      _host(
        const MediaCard(title: 'Blade Runner', action: MediaCardAction.open),
      ),
    );

    final detector = tester.widget<FocusableActionDetector>(
      find.byType(FocusableActionDetector).first,
    );
    expect(detector.enabled, isFalse);
  });
}
