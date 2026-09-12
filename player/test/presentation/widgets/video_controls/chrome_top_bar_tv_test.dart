// The top bar's pills are pointer-only today, which leaves Back and Cast
// unreachable from a remote: the only way out of playback is Android's back
// button, and there is no way to reach the cast picker at all.
//
// Tier-independent on purpose -- FocusHighlight already hides its ring under
// touch and mouse and shows it for directional traversal, so this asserts the
// pills are focus stops on every platform, which is also what desktop keyboard
// users were missing.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/widgets/video_controls/chrome_top_bar.dart';

void main() {
  testWidgets('the back pill is a focus stop and activates from the keyboard',
      (tester) async {
    var backs = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChromeTopBar(
            title: 'An Episode',
            onBack: () => backs++,
          ),
        ),
      ),
    );

    final back = find.byKey(ChromeTopBar.backKey);
    expect(back, findsOneWidget);

    // `Focus.of` searches *upward* from the context it is handed, and the
    // focus stop `FocusHighlight` installs sits *inside* the pill, below the
    // keyed `GlassPill` element. Handing it the pill's own label starts the
    // search under that wrapper; handing it `back` would start above the
    // wrapper and find only MaterialApp's FocusScopeNode.
    final node = Focus.of(tester.element(find.text('Back')));
    node.requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(backs, 1);
  });

  testWidgets('the cast pill is a focus stop and activates from the keyboard',
      (tester) async {
    var casts = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChromeTopBar(
            title: 'An Episode',
            castAction: const Icon(Icons.cast_rounded),
            onCastTap: () => casts++,
          ),
        ),
      ),
    );

    final cast = find.byKey(ChromeTopBar.castKey);
    expect(cast, findsOneWidget);

    // Same upward-search caveat as the back pill above: read the node from
    // the cast glyph, which sits under the FocusHighlight wrapper.
    Focus.of(tester.element(find.byIcon(Icons.cast_rounded))).requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(casts, 1);
  });

  // The title pill has no onTap, so GlassPill returns its content before ever
  // reaching the focus wrapper: it is not a focus stop and needs no test. It
  // matters that it stays that way -- it sits between Back and Cast in reading
  // order, and a focus stop there would cost a keypress to cross with nothing
  // to activate.
}
