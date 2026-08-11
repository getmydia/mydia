// End-to-end proof that content clears the dock, measured against a real
// BottomNav inside a real shell rather than against a hardcoded guess.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/layout/dock_insets.dart';
import 'package:player/presentation/widgets/media_poster.dart';

import '../test_utils/dock_harness.dart';
import 'screens/library/library_screen_layout_test.dart' show pumpLibrary;

void main() {
  // LibraryScreen awaits LibrarySortController before it queries, and that
  // controller reads flutter_secure_storage. Without the mock the read never
  // completes, the sort spinner spins forever, and pumpAndSettle times out.
  //
  // `show pumpLibrary` imports the function but NOT the library test file's
  // own setUp, which is where this mock normally lives (see the comment at
  // library_screen_layout_test.dart:238). Borrowing a pump helper across test
  // files means borrowing its fixtures explicitly.
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  group('DockInsets under a real BottomNav', () {
    testWidgets('reserves more than the 100.0 screens used to hardcode',
        (tester) async {
      // 600 wide, not 400. Setting `view.physicalSize` really constrains
      // layout (unlike Task 2, which only wraps a MediaQueryData and leaves
      // the default ~800 view), and BottomNav's Row overflows by 152px at
      // 400. That is a pre-existing responsive limit of the dock, unrelated
      // to clearance; see the note at the end of this plan. Still below
      // Breakpoints.tablet (900), so this is the mobile branch with a dock.
      tester.view.physicalSize = const Size(600, 800);
      tester.view.devicePixelRatio = 1.0;
      tester.view.padding = const FakeViewPadding(bottom: 34);
      addTearDown(tester.view.reset);

      late double reserved;
      await tester.pumpWidget(
        ProviderScope(
          child: shellHarness(
            child: Builder(
              builder: (context) {
                reserved = DockInsets.bottomOf(context);
                return const SizedBox.expand();
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The dock measures 117 at this inset; the old hardcoded value was 100.
      expect(reserved, dockHeightOf(tester) + DockInsets.dockGap);
      expect(reserved, greaterThan(100));
    });
  });

  group('library grid', () {
    testWidgets('scrolls its last poster clear of the dock', (tester) async {
      await pumpLibrary(
        tester,
        // 600 wide, not 400: at 400 the library app bar's Row overflows on a
        // pre-existing responsive bug unrelated to this change, and the test
        // would fail for the wrong reason. Still below Breakpoints.tablet
        // (900), so this is the mobile branch with a dock.
        size: const Size(600, 900),
        bottomInset: 34,
        wrap: (child) => shellHarness(child: child),
      );

      // Scroll past the end; the grid clamps at its own extent.
      await tester.drag(find.byType(GridView), const Offset(0, -5000));
      await tester.pumpAndSettle();

      expectClearsDock(tester, find.byType(MediaPoster).last);
    });
  });
}
