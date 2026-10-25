import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/l10n/gen/app_localizations.dart';
import 'package:player/presentation/screens/calendar/calendar_row.dart';
import 'package:player/presentation/widgets/source_artwork.dart';

import 'calendar_test_items.dart';

ItemSummary _entry({
  required String id,
  required DateTime airDate,
  bool playable = false,
  ItemKind kind = ItemKind.episode,
}) =>
    calendarEntry(id, airDate,
        playable: playable, kind: kind, season: 3, episode: 4);

Future<void> _pump(WidgetTester tester, ItemSummary entry) {
  return tester.pumpWidget(
    ProviderScope(
      overrides: [
        sourceArtworkProvider.overrideWith((ref, key) async => null),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SizedBox(
              height: 43,
              child: CalendarRow(entry: entry, today: DateTime(2026, 8, 27))),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('a future entry is marked upcoming and cannot be played',
      (tester) async {
    await _pump(tester, _entry(id: '2', airDate: DateTime(2026, 9, 3)));
    expect(find.byKey(const ValueKey('calendar-upcoming-2')), findsOneWidget);
    expect(find.text('Upcoming'), findsOneWidget);
    expect(find.byKey(const ValueKey('calendar-play-2')), findsNothing);
  });

  testWidgets('an aired entry with no file reads as not in the library',
      (tester) async {
    await _pump(tester, _entry(id: '4', airDate: DateTime(2026, 8, 20)));
    expect(find.byKey(const ValueKey('calendar-absent-4')), findsOneWidget);
    expect(find.text('Not in library'), findsOneWidget);
  });

  testWidgets("today's entry with no file reads as not in the library",
      (tester) async {
    await _pump(tester, _entry(id: '5', airDate: DateTime(2026, 8, 27)));
    expect(find.byKey(const ValueKey('calendar-absent-5')), findsOneWidget);
  });

  testWidgets('an episode shows its show and numbering', (tester) async {
    await _pump(tester, _entry(id: '6', airDate: DateTime(2026, 9, 3)));
    expect(find.text('A Show'), findsOneWidget);
    expect(find.text('S03E04'), findsOneWidget);
  });

  testWidgets('a movie shows its own title and Movie', (tester) async {
    await _pump(tester,
        _entry(id: '7', airDate: DateTime(2026, 9, 3), kind: ItemKind.movie));
    expect(find.text('An Episode'), findsOneWidget);
    expect(find.text('Movie'), findsOneWidget);
    expect(find.textContaining('S0'), findsNothing);
  });
}
