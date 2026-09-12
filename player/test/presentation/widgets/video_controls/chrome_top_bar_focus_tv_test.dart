// Television-tier proof that the playback top bar's Back and Cast pills are
// focus stops a D-pad can reach and activate. Without them the only way out of
// playback is Android's back button and the cast picker cannot be reached at
// all.
//
// The focus-stop wrapper in `ChromeTopBar._focusablePill` is gated on
// InputCapabilities.directionalPrimary, so the behaviour pinned here is
// directional-tier-only: off-tier the pills are plain pointer targets and the
// chrome keeps the Tab order it had before this branch. That gate is also why
// this file must not run in the default suite -- with it in place a plain
// `flutter test` finds no focus stops and fails, which is the intended signal
// that the file belongs to the television tier. It skips itself unless the
// whole process is compiled with the define, and CI runs it explicitly in the
// "Run television-tier tests" step.
//
// Requires --dart-define=MYDIA_FORCE_TV=true; see login_tv_test.dart for why
// this file skips itself rather than failing without it.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/player/input_capabilities.dart';
import 'package:player/presentation/widgets/video_controls/chrome_top_bar.dart';

void main() {
  final skipReason = InputCapabilities.directionalPrimary
      ? false
      : 'requires --dart-define=MYDIA_FORCE_TV=true to force '
          'InputCapabilities.directionalPrimary; forcedTv is a compile-time '
          'flag (bool.fromEnvironment), so this file is a deliberate no-op '
          'unless the whole test process is compiled with that define. CI '
          'runs it explicitly in the "Run television-tier tests" step.';

  group('ChromeTopBar focus stops (requires MYDIA_FORCE_TV=true)', () {
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
  }, skip: skipReason);

  // The title pill has no onTap, so GlassPill returns its content before ever
  // reaching the focus wrapper: it is not a focus stop and needs no test. It
  // matters that it stays that way -- it sits between Back and Cast in reading
  // order, and a focus stop there would cost a keypress to cross with nothing
  // to activate.
}
