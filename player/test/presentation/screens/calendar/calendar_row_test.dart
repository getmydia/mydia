import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/sources/item.dart';
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
        home: Scaffold(
          body: CalendarRow(entry: entry, today: DateTime(2026, 8, 27)),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('a playable past entry offers a play control', (tester) async {
    await _pump(
      tester,
      _entry(id: '1', airDate: DateTime(2026, 8, 20), playable: true),
    );

    expect(find.byKey(const ValueKey('calendar-play-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('calendar-upcoming-1')), findsNothing);
    expect(find.byKey(const ValueKey('calendar-absent-1')), findsNothing);
  });

  testWidgets('a future entry is marked upcoming and cannot be played',
      (tester) async {
    await _pump(
      tester,
      _entry(id: '2', airDate: DateTime(2026, 8, 30), playable: false),
    );

    expect(find.byKey(const ValueKey('calendar-upcoming-2')), findsOneWidget);
    expect(find.byKey(const ValueKey('calendar-play-2')), findsNothing);
  });

  testWidgets('a future entry that is already in the library can be played',
      (tester) async {
    await _pump(
      tester,
      _entry(id: '3', airDate: DateTime(2026, 8, 30), playable: true),
    );

    expect(find.byKey(const ValueKey('calendar-play-3')), findsOneWidget);
    expect(find.byKey(const ValueKey('calendar-upcoming-3')), findsNothing);
  });

  testWidgets('an aired entry with no file reads as not in the library',
      (tester) async {
    await _pump(
      tester,
      _entry(id: '4', airDate: DateTime(2026, 8, 20), playable: false),
    );

    expect(find.byKey(const ValueKey('calendar-absent-4')), findsOneWidget);
    expect(find.text('Not in library'), findsOneWidget);
    expect(find.byKey(const ValueKey('calendar-play-4')), findsNothing);
  });

  testWidgets('an episode shows its season and episode numbers',
      (tester) async {
    await _pump(
      tester,
      _entry(id: '5', airDate: DateTime(2026, 8, 20), playable: true),
    );

    expect(find.textContaining('S03E04'), findsOneWidget);
    expect(find.text('A Show'), findsOneWidget);
  });

  testWidgets('a movie shows its own title and no episode numbering',
      (tester) async {
    await _pump(
      tester,
      _entry(
        id: '6',
        airDate: DateTime(2026, 8, 20),
        playable: true,
        kind: ItemKind.movie,
      ),
    );

    expect(find.textContaining('S0'), findsNothing);
    expect(find.text('Movie'), findsOneWidget);
  });
}
