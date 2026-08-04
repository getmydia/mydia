import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/layout/window_chrome_inset.dart';

/// The shell's child, marked so the test can measure where it starts.
const Key _childKey = Key('shell-child');

void main() {
  group('shell content under a reserved window chrome strip', () {
    testWidgets('a SafeArea gutter pushes the child clear of the strip',
        (tester) async {
      await tester.pumpWidget(
        const MediaQuery(
          data: MediaQueryData(
            padding: EdgeInsets.only(top: kMacTitleBarOverlap),
          ),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: SafeArea(
              top: true,
              bottom: false,
              left: false,
              right: false,
              child: SizedBox(key: _childKey, height: 100, width: 100),
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
        'the gutter consumes the inset, so a nested AppBar does not inset '
        'a second time', (tester) async {
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            padding: EdgeInsets.only(top: kMacTitleBarOverlap),
          ),
          child: MaterialApp(
            home: SafeArea(
              top: true,
              bottom: false,
              left: false,
              right: false,
              child: Scaffold(
                appBar: AppBar(title: const Text('probe')),
                body: const SizedBox(key: _childKey),
              ),
            ),
          ),
        ),
      );

      // The app bar starts at the gutter, not at gutter + inset. If SafeArea
      // did not remove the padding it consumed, this would be 2x the overlap.
      expect(
        tester.getRect(find.byType(AppBar)).top,
        kMacTitleBarOverlap,
      );
    });

    testWidgets(
        'CONTROL: with no gutter above it, an AppBar insets itself by growing',
        (tester) async {
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
