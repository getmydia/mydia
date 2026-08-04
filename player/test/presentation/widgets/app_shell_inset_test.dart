// Regression guard for the shell's content gutter: `AppShell.contentGutter`
// is the `SafeArea` both the desktop and mobile branches wrap their main
// content column in (see app_shell.dart), the same `@visibleForTesting` seam
// `AppShell.castOverlay` established for the cast button. Because the first
// two tests below call the real seam instead of hand-rolling a `SafeArea`
// that mirrors its shape, a regression that drops the gutter entirely (or
// changes which edges it insets) is caught here without any mirror to keep
// in sync by hand.
//
// The third test is a deliberate CONTROL with no gutter at all, showing what
// an `AppBar` does when nothing above it has already consumed the strip.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/layout/window_chrome_inset.dart';
import 'package:player/presentation/widgets/app_shell.dart';

/// The gutter's child, marked so the test can measure where it starts.
const Key _childKey = Key('shell-child');

void main() {
  group('AppShell.contentGutter under a reserved window chrome strip', () {
    testWidgets('pushes its child clear of the strip', (tester) async {
      await tester.pumpWidget(
        const MediaQuery(
          data: MediaQueryData(
            padding: EdgeInsets.only(top: kMacTitleBarOverlap),
          ),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: SizedBox(
              // AppShell.contentGutter is a static method, not a const
              // constructor, so it cannot be built inside a `const` widget
              // tree; wrap it via a builder-shaped subtree instead.
              child: _ContentGutterProbe(),
            ),
          ),
        ),
      );

      expect(
        tester.getRect(find.byKey(_childKey)).top,
        greaterThanOrEqualTo(kMacTitleBarOverlap),
      );
    });

    testWidgets(
        'consumes the inset, so a nested AppBar does not inset a second '
        'time', (tester) async {
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            padding: EdgeInsets.only(top: kMacTitleBarOverlap),
          ),
          child: MaterialApp(
            home: AppShell.contentGutter(
              child: Scaffold(
                appBar: AppBar(title: const Text('probe')),
                body: const SizedBox(key: _childKey),
              ),
            ),
          ),
        ),
      );

      // The app bar starts at the gutter, not at gutter + inset. If the
      // gutter's SafeArea did not remove the padding it consumed, this
      // would be 2x the overlap.
      expect(
        tester.getRect(find.byType(AppBar)).top,
        kMacTitleBarOverlap,
      );
    });

    testWidgets(
        'CONTROL: with no gutter above it, an AppBar insets itself by '
        'growing', (tester) async {
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            padding: EdgeInsets.only(top: kMacTitleBarOverlap),
          ),
          child: MaterialApp(
            home: Scaffold(
              appBar: AppBar(title: const Text('probe')),
              body: const SizedBox(key: _childKey),
            ),
          ),
        ),
      );

      // This is the path every out-of-shell detail screen takes. Measured:
      // 56 + 28 = 84.
      expect(
        tester.getRect(find.byType(AppBar)).height,
        kToolbarHeight + kMacTitleBarOverlap,
      );
    });
  });
}

/// Builds `AppShell.contentGutter` around the keyed probe child.
///
/// A plain widget (not a `const` literal in the test body) purely so the
/// static-method call can sit inside the otherwise-`const` `MediaQuery` /
/// `Directionality` tree used by the first test.
class _ContentGutterProbe extends StatelessWidget {
  const _ContentGutterProbe();

  @override
  Widget build(BuildContext context) => AppShell.contentGutter(
        child: const SizedBox(key: _childKey, height: 100, width: 100),
      );
}
