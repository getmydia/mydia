import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/settings/settings_service.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/presentation/screens/calendar/calendar_dates.dart';
import 'package:player/presentation/screens/calendar/calendar_screen.dart';
import 'package:player/presentation/screens/detail/detail_links.dart';
import 'package:player/presentation/screens/settings/settings_controller.dart';

import '../../../test_utils/mock_auth_storage.dart';
import '../sources/fake_capable_source.dart';
import '../sources/fake_media_source.dart';
import '../sources/listing_harness.dart';
import 'calendar_test_items.dart';

const _toggle = ValueKey('calendar-view-toggle');
const _weekView = ValueKey('calendar-week-view');
const _agendaView = ValueKey('calendar-agenda-view');

List<Override> _settings(MockAuthStorage storage) => [
      settingsServiceProvider
          .overrideWithValue(SettingsService(storage: storage)),
    ];

Future<PushedLocations> _pump(
  WidgetTester tester, {
  required MockAuthStorage storage,
  required List<FakeCapableSource> sources,
  SourceId screenFor = fakeSourceId,
}) =>
    pumpListing(
      tester,
      CalendarScreen(sourceId: screenFor),
      sources: sources,
      overrides: _settings(storage),
    );

void main() {
  final today = truncateToDay(DateTime.now());
  FakeCapableSource sourceWith(List<ItemSummary> entries) =>
      FakeCapableSource()..calendarResult = entries;

  testWidgets('opens on the week view when nothing is stored', (tester) async {
    await _pump(
      tester,
      storage: MockAuthStorage(),
      sources: [
        sourceWith([calendarEntry('today', today)])
      ],
    );

    expect(find.byKey(_weekView), findsOneWidget);
    expect(find.byKey(_agendaView), findsNothing);
    expect(find.byTooltip('Agenda view'), findsOneWidget);
  });

  testWidgets('opens on the agenda when that was the last choice',
      (tester) async {
    final storage = MockAuthStorage()
      ..seedData({'calendar_view_mode': 'agenda'});

    await _pump(
      tester,
      storage: storage,
      sources: [
        sourceWith([calendarEntry('today', today)])
      ],
    );

    expect(find.byKey(_agendaView), findsOneWidget);
    expect(find.byKey(_weekView), findsNothing);
    expect(find.byTooltip('Week view'), findsOneWidget);
  });

  testWidgets('the toggle switches views and remembers the choice',
      (tester) async {
    final storage = MockAuthStorage();
    await _pump(
      tester,
      storage: storage,
      sources: [
        sourceWith([calendarEntry('today', today)])
      ],
    );

    await tester.tap(find.byKey(_toggle));
    await tester.pumpAndSettle();

    expect(find.byKey(_agendaView), findsOneWidget);
    expect(storage.contents['calendar_view_mode'], 'agenda');

    await tester.tap(find.byKey(_toggle));
    await tester.pumpAndSettle();

    expect(find.byKey(_weekView), findsOneWidget);
    expect(storage.contents['calendar_view_mode'], 'week');
  });

  testWidgets('Today brings the week view back to this week', (tester) async {
    await _pump(
      tester,
      storage: MockAuthStorage(),
      sources: [
        sourceWith([calendarEntry('today', today)])
      ],
    );
    final todayHeader = find.byKey(ValueKey('calendar-day-${isoDate(today)}'));

    await tester.tap(find.byKey(const ValueKey('calendar-week-next')));
    await tester.pumpAndSettle();
    expect(todayHeader, findsNothing);

    await tester.tap(find.text('Today'));
    await tester.pumpAndSettle();

    expect(todayHeader, findsOneWidget);
    expect(find.byKey(const ValueKey('calendar-entry-today')), findsOneWidget);
  });

  testWidgets('an empty window shows the empty state in both views',
      (tester) async {
    await _pump(
      tester,
      storage: MockAuthStorage(),
      sources: [sourceWith(const [])],
    );

    expect(find.byKey(const ValueKey('calendar-empty')), findsOneWidget);

    await tester.tap(find.byKey(_toggle));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('calendar-empty')), findsOneWidget);
  });

  testWidgets('asks the source for the window around today and opens an entry',
      (tester) async {
    final source = sourceWith([calendarEntry('e1', today, playable: true)]);
    final pushed = await _pump(
      tester,
      storage: MockAuthStorage(),
      sources: [source],
    );

    expect(source.calls.single, startsWith('calendar('));

    await tester.tap(find.byKey(const ValueKey('calendar-row-e1')));
    await tester.pumpAndSettle();
    expect(pushed.last, '/s/acc1:owner:aa11/episode/e1');
  });

  testWidgets('an entry with no version has no play button', (tester) async {
    await _pump(
      tester,
      storage: MockAuthStorage(),
      sources: [
        sourceWith([
          calendarEntry('bare', today),
          calendarEntry('ready', today, playable: true),
        ]),
      ],
    );

    expect(find.byKey(const ValueKey('calendar-play-bare')), findsNothing);
    expect(find.byKey(const ValueKey('calendar-play-ready')), findsOneWidget);
  });

  testWidgets('play goes to the source player with the default version',
      (tester) async {
    final entry = calendarEntry('ready', today, playable: true);
    final pushed = await _pump(
      tester,
      storage: MockAuthStorage(),
      sources: [
        sourceWith([entry])
      ],
    );

    await tester.tap(find.byKey(const ValueKey('calendar-play-ready')));
    await tester.pumpAndSettle();

    expect(
      pushed.last,
      sourcePlayerLocation(entry.ref, fileId: 'file-ready', title: entry.title),
    );
  });

  testWidgets('shows the calendar of the source it is scoped to',
      (tester) async {
    final a =
        sourceWith([calendarEntry('a1', today, title: 'First Source Ep')]);
    final b = FakeCapableSource(id: otherSourceId)
      ..calendarResult = [
        calendarEntry('b1', today,
            sourceId: otherSourceId, title: 'Second Source Ep'),
      ];
    await _pump(
      tester,
      storage: MockAuthStorage(),
      sources: [a, b],
      screenFor: otherSourceId,
    );

    expect(find.textContaining('Second Source Ep'), findsOneWidget);
    expect(find.textContaining('First Source Ep'), findsNothing);
    expect(a.calls, isEmpty);
  });
}
