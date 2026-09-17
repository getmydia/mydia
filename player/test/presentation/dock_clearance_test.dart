// End-to-end proof that content clears the dock, measured against a real
// BottomNav inside a real shell rather than against a hardcoded guess.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/auth/auth_status.dart';
import 'package:player/core/graphql/graphql_provider.dart';
import 'package:player/core/layout/dock_insets.dart';
import 'package:player/domain/models/calendar_entry.dart';
import 'package:player/presentation/screens/calendar/calendar_controller.dart';
import 'package:player/presentation/screens/calendar/calendar_screen.dart';
import 'package:player/presentation/screens/calendar/calendar_view_mode.dart';
import 'package:player/presentation/widgets/media_poster.dart';

import '../test_utils/dock_harness.dart';
import 'screens/library/library_screen_layout_test.dart' show pumpLibrary;

/// The real `AuthStateNotifier` reads secure storage on build. The calendar's
/// `FreshnessHeader` watches it, so the calendar test needs this stub.
class _StubAuthState extends AuthStateNotifier {
  @override
  AsyncValue<AuthStatus> build() =>
      const AsyncValue.data(AuthStatus.authenticated);
}

/// Thirty episodes over ten days from today: far more than 800px of rows, so
/// the footer starts well below the fold.
class _FixedCalendarController extends CalendarController {
  @override
  Stream<List<CalendarEntry>> build() {
    final today = DateTime.now();
    return Stream.value([
      for (var i = 0; i < 30; i++)
        CalendarEntry(
          id: 'e$i',
          kind: CalendarEntryKind.episode,
          airDate: DateTime(today.year, today.month, today.day + i ~/ 3),
          title: 'Episode $i',
          mediaItemId: '7',
          mediaItemTitle: 'The Lantern Keepers',
        ),
    ]);
  }
}

/// Twenty episodes all airing today, so the week view's single day overflows
/// the viewport on its own.
class _BusyDayCalendarController extends CalendarController {
  @override
  Stream<List<CalendarEntry>> build() {
    final today = DateTime.now();
    return Stream.value([
      for (var i = 0; i < 20; i++)
        CalendarEntry(
          id: 'busy$i',
          kind: CalendarEntryKind.episode,
          airDate: DateTime(today.year, today.month, today.day),
          title: 'Episode $i',
          mediaItemId: '7',
          mediaItemTitle: 'The Lantern Keepers',
        ),
    ]);
  }
}

/// Pins the calendar layout without touching settings storage.
class _FixedViewMode extends CalendarViewModeController {
  _FixedViewMode(this.mode);

  final CalendarViewMode mode;

  @override
  Future<CalendarViewMode> build() async => mode;
}

Future<void> _pumpCalendar(
  WidgetTester tester, {
  required CalendarController Function() controller,
  required CalendarViewMode mode,
}) async {
  // Same 600-wide mobile layout and 34px home indicator as the library cases.
  tester.view.physicalSize = const Size(600, 800);
  tester.view.devicePixelRatio = 1.0;
  tester.view.padding = const FakeViewPadding(bottom: 34);
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authStateProvider.overrideWith(_StubAuthState.new),
        calendarControllerProvider.overrideWith(controller),
        calendarViewModeControllerProvider
            .overrideWith(() => _FixedViewMode(mode)),
      ],
      child: shellHarness(child: const CalendarScreen()),
    ),
  );
  await tester.pumpAndSettle();

  await tester.drag(find.byType(CustomScrollView), const Offset(0, -20000));
  await tester.pumpAndSettle();
}

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
      // 600 wide, not 400. Setting `view.physicalSize` genuinely constrains
      // layout, unlike `app_shell_dock_inset_test.dart`, which only wraps a
      // `MediaQueryData` and so leaves the default ~800 view in place. At 400
      // BottomNav's Row overflows by 152px.
      //
      // That overflow is a pre-existing responsive limit of the dock, not a
      // clearance problem, and it is NOT evidence of a bug on real 400px
      // phones: widget tests render text in a placeholder font whose every
      // glyph is a full em square, so labels measure far wider here than on a
      // device. `library_screen_layout_test.dart` carries the same caveat.
      //
      // 600 is still below Breakpoints.tablet (900), so this is the mobile
      // branch and the dock is present.
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

  group('calendar', () {
    testWidgets('scrolls the agenda footer clear of the dock', (tester) async {
      await _pumpCalendar(
        tester,
        controller: _FixedCalendarController.new,
        mode: CalendarViewMode.agenda,
      );

      expectClearsDock(
        tester,
        find.text('That is everything scheduled in the next 90 days.'),
      );
    });

    testWidgets('scrolls the last row of a busy day clear of the dock',
        (tester) async {
      await _pumpCalendar(
        tester,
        controller: _BusyDayCalendarController.new,
        mode: CalendarViewMode.week,
      );

      expectClearsDock(
        tester,
        find.byKey(const ValueKey('calendar-entry-busy19')),
      );
    });
  });
}
