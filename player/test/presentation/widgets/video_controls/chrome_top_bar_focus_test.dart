// The top bar's pills are pointer-only today, which leaves Back and Cast
// unreachable from a remote: the only way out of playback is Android's back
// button, and there is no way to reach the cast picker at all.
//
// No tier flag is needed and none is passed. FocusHighlight gates its ring on
// traversal -- keyboard and directional only -- rather than on the input tier,
// so the pills are focus stops on every platform, and what is asserted here is
// exactly what a desktop keyboard user gets too. That is also why this file
// deliberately does not enrol in the TV-tier job: it is named
// `chrome_top_bar_focus_test.dart`, not `*_tv_test.dart`, so CI's
// `--dart-define=MYDIA_FORCE_TV=true` run never picks it up.

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

    // The title pill has no action, so it must not be a focus stop: it sits
    // between Back and Cast in reading order, and a stop there would cost a
    // keypress with nothing to activate. Asserted rather than trusted to the
    // comment in the file header, because moving the wrapper one level up
    // would silently make it focusable.
    expect(
      Focus.maybeOf(tester.element(find.byKey(ChromeTopBar.titleKey))),
      isNull,
    );
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
