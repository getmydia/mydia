import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/auth/auth_status.dart';
import 'package:player/core/cast/cast_capabilities.dart';
import 'package:player/core/cast/cast_providers.dart';
import 'package:player/core/graphql/graphql_provider.dart';
import 'package:player/core/settings/settings_service.dart';
import 'package:player/domain/models/calendar_entry.dart';
import 'package:player/presentation/screens/calendar/calendar_controller.dart';
import 'package:player/presentation/screens/calendar/calendar_dates.dart';
import 'package:player/presentation/screens/calendar/calendar_screen.dart';
import 'package:player/presentation/screens/settings/settings_controller.dart';

import '../../../test_utils/mock_auth_storage.dart';

/// The real notifier reaches for secure storage on build, which a widget
/// test has no business doing. Mirrors `browse_scaffold_test.dart`.
class _StubAuthState extends AuthStateNotifier {
  @override
  AsyncValue<AuthStatus> build() =>
      const AsyncValue.data(AuthStatus.authenticated);
}

class _StubCalendar extends CalendarController {
  _StubCalendar(this.entries);

  final List<CalendarEntry> entries;

  @override
  Stream<List<CalendarEntry>> build() => Stream.value(entries);

  @override
  Future<void> refresh() async {}
}

CalendarEntry _entry(String id, DateTime airDate) => CalendarEntry(
      id: id,
      kind: CalendarEntryKind.episode,
      airDate: airDate,
      title: 'Episode $id',
      seasonNumber: 1,
      episodeNumber: 1,
      mediaItemId: '7',
      mediaItemTitle: 'A Show',
    );

const _toggle = ValueKey('calendar-view-toggle');
const _weekView = ValueKey('calendar-week-view');
const _agendaView = ValueKey('calendar-agenda-view');

Future<void> _pump(
  WidgetTester tester, {
  required MockAuthStorage storage,
  required List<CalendarEntry> entries,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authStateProvider.overrideWith(_StubAuthState.new),
        castCapabilitiesProvider
            .overrideWithValue(const CastCapabilities.full()),
        settingsServiceProvider
            .overrideWithValue(SettingsService(storage: storage)),
        calendarControllerProvider.overrideWith(() => _StubCalendar(entries)),
      ],
      child: const MaterialApp(home: CalendarScreen()),
    ),
  );
  await tester.pump();
  await tester.pumpAndSettle();
}

void main() {
  final today = truncateToDay(DateTime.now());
  final entries = [_entry('today', today)];

  testWidgets('opens on the week view when nothing is stored', (tester) async {
    await _pump(tester, storage: MockAuthStorage(), entries: entries);

    expect(find.byKey(_weekView), findsOneWidget);
    expect(find.byKey(_agendaView), findsNothing);
    expect(find.byTooltip('Agenda view'), findsOneWidget);
  });

  testWidgets('opens on the agenda when that was the last choice',
      (tester) async {
    final storage = MockAuthStorage()
      ..seedData({'calendar_view_mode': 'agenda'});

    await _pump(tester, storage: storage, entries: entries);

    expect(find.byKey(_agendaView), findsOneWidget);
    expect(find.byKey(_weekView), findsNothing);
    expect(find.byTooltip('Week view'), findsOneWidget);
  });

  testWidgets('the toggle switches views and remembers the choice',
      (tester) async {
    final storage = MockAuthStorage();
    await _pump(tester, storage: storage, entries: entries);

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
    await _pump(tester, storage: MockAuthStorage(), entries: entries);
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
    await _pump(tester, storage: MockAuthStorage(), entries: const []);

    expect(find.byKey(const ValueKey('calendar-empty')), findsOneWidget);

    await tester.tap(find.byKey(_toggle));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('calendar-empty')), findsOneWidget);
  });
}
