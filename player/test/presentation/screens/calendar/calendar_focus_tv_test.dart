// The calendar timeline remembers its place on a television: a move into the
// list from the bar above lands on the entry that last had focus there, else
// the first entry on screen rather than one built above the viewport, and a
// jump (Today, a day picked in the month sheet) starts the list afresh.
//
// The real CalendarScreen inside the shell's real content region (see
// `tv_shell_harness.dart`), at 1920x1080. The timeline opens on today, so
// the past days above it are laid out in the list's cache extent, above the
// viewport, where a first entry must not land.
//
// Requires --dart-define=MYDIA_FORCE_TV=true.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/presentation/screens/calendar/calendar_dates.dart';
import 'package:player/presentation/screens/calendar/calendar_screen.dart';
import 'package:player/presentation/widgets/source_artwork.dart';

import '../../../test_utils/tv_shell_harness.dart';
import '../sources/fake_capable_source.dart';
import '../sources/fake_media_source.dart';
import 'calendar_test_items.dart';

void main() {
  group('Calendar focus memory (requires MYDIA_FORCE_TV=true)', () {
    final today = truncateToDay(DateTime.now());
    DateTime day(int offset) =>
        DateTime(today.year, today.month, today.day + offset);

    Key entry(String id) => ValueKey('calendar-entry-$id');
    const monthButton = Key('calendar-month-button');
    const todayButton = Key('calendar-today-button');

    late TvShell shell;

    Future<void> pumpCalendar(WidgetTester tester) async {
      final source = FakeCapableSource()
        ..calendarResult = [
          // Ten past days, above today and so above the viewport on open.
          // In date order, as the server sends them: the timeline keeps it.
          for (var i = 10; i >= 1; i--) calendarEntry('p$i', day(-i)),
          for (var i = 0; i < 3; i++) calendarEntry('t$i', today),
          // Enough future days that the far end is never built near today.
          for (var i = 1; i <= 60; i++) calendarEntry('f$i', day(i)),
        ];
      shell = TvShell();
      await shell.pump(
        tester,
        const CalendarScreen(sourceId: fakeSourceId),
        overrides: [
          mediaSourceProvider(fakeSourceId).overrideWithValue(source),
          sourceArtworkProvider.overrideWith((ref, key) async => null),
        ],
      );
    }

    ScrollPosition timeline(WidgetTester tester) => tester
        .state<ScrollableState>(find.descendant(
          of: find.byKey(const ValueKey('calendar-timeline')),
          matching: find.byType(Scrollable),
        ))
        .position;

    testWidgets(
        'the list entered for the first time lands on the first entry '
        'on screen', (tester) async {
      await pumpCalendar(tester);
      // Built above the viewport, so a first entry by index would land here.
      expect(find.byKey(entry('p1'), skipOffstage: false), findsOneWidget);
      await focusIn(tester, monthButton);

      await press(tester, LogicalKeyboardKey.arrowDown);

      expectFocusIn(entry('t0'));
    });

    testWidgets('the list is re-entered on the entry that left it',
        (tester) async {
      await pumpCalendar(tester);
      await focusIn(tester, entry('f4'));
      // However focus reached the bar, coming back down returns to f4 rather
      // than whichever entry sits nearest the button.
      await focusIn(tester, monthButton);

      await press(tester, LogicalKeyboardKey.arrowDown);

      expectFocusIn(entry('f4'));
    });

    testWidgets('Today starts the list afresh on its first entry',
        (tester) async {
      await pumpCalendar(tester);
      final position = timeline(tester);
      position.jumpTo(position.pixels + 2400);
      await tester.pumpAndSettle();
      await focusIn(tester, entry('f40'));

      await focusIn(tester, todayButton);
      await press(tester, LogicalKeyboardKey.enter);
      expect(find.byKey(entry('f40'), skipOffstage: false), findsNothing,
          reason: 'the jump back to today unbuilt the remembered entry');

      await press(tester, LogicalKeyboardKey.arrowDown);

      expectFocusIn(entry('t0'));
    });

    testWidgets('LEFT from an entry reaches the rail, RIGHT returns',
        (tester) async {
      await pumpCalendar(tester);
      await focusIn(tester, monthButton);
      await press(tester, LogicalKeyboardKey.arrowDown);
      await press(tester, LogicalKeyboardKey.arrowDown);
      expectFocusIn(entry('t1'));

      await press(tester, LogicalKeyboardKey.arrowLeft);
      expect(shell.sidebarRow.hasPrimaryFocus, isTrue,
          reason: 'focus is on ${describeFocus()}');

      await press(tester, LogicalKeyboardKey.arrowRight);
      expectFocusIn(entry('t1'));
    });
  }, skip: tvSkipReason);
}
