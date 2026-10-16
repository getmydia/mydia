import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/presentation/screens/calendar/calendar_card.dart';
import 'package:player/presentation/screens/calendar/calendar_artwork.dart';
import 'package:player/presentation/widgets/source_artwork.dart';

import '../detail/detail_harness.dart';
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
          body: SizedBox(
            width: 300,
            height: 210,
            child: CalendarCard(
                entry: entry, today: DateTime(2026, 8, 27), imageHeight: 150),
          ),
        ),
      ),
    ),
  );
}

/// Mounts a playable entry over [source] and taps its play control. Returns
/// the locations the row pushed.
Future<List<String>> _tapPlay(
  WidgetTester tester,
  ScriptedDetailSource source,
  ItemSummary entry,
) async {
  final pushed = <String>[];
  await pumpDetailScreen(
    tester,
    Scaffold(
      body: CalendarCard(
          entry: entry, today: DateTime(2026, 8, 27), imageHeight: 150),
    ),
    [source],
    size: const Size(1600, 900),
    routes: [
      GoRoute(
        path: '/s/:sourceId/player/:itemId',
        builder: (context, state) {
          pushed.add(state.uri.toString());
          return const Scaffold(body: SizedBox.shrink());
        },
      ),
    ],
  );
  await tester
      .tap(find.byKey(ValueKey('calendar-play-${entry.ref.externalId}')));
  // The best version is picked after real device detection: poll in real time.
  for (var i = 0; i < 250 && pushed.isEmpty; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
  return pushed;
}

void main() {
  testWidgets('play pushes the best version of the fetched item',
      (tester) async {
    final entry =
        _entry(id: '7', airDate: DateTime(2026, 8, 20), playable: true);
    final source = ScriptedDetailSource(
      detailOf: (ref) => ItemDetail(
        summary: entry,
        versions: const [
          MediaVersion(id: 'sd', height: 480),
          MediaVersion(id: 'hd', height: 1080),
        ],
      ),
    );

    final pushed = await _tapPlay(tester, source, entry);

    expect(pushed, hasLength(1));
    expect(Uri.parse(pushed.single).queryParameters['fileId'], 'hd');
  });

  testWidgets('play falls back to the listed version when the fetch fails',
      (tester) async {
    final entry =
        _entry(id: '8', airDate: DateTime(2026, 8, 20), playable: true);
    final source = ScriptedDetailSource(
      detailOf: (ref) => throw StateError('server unreachable'),
    );

    final pushed = await _tapPlay(tester, source, entry);

    expect(pushed, hasLength(1));
    expect(Uri.parse(pushed.single).queryParameters['fileId'], 'file-8');
  });

  testWidgets('a card shows title, numbering and a play control',
      (tester) async {
    await _pump(tester,
        _entry(id: '1', airDate: DateTime(2026, 8, 20), playable: true));

    expect(find.text('A Show'), findsOneWidget);
    expect(find.textContaining('S03E04'), findsOneWidget);
    expect(find.byKey(const ValueKey('calendar-play-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('calendar-new-1')), findsNothing);
  });

  testWidgets("today's card is marked new", (tester) async {
    await _pump(tester,
        _entry(id: '2', airDate: DateTime(2026, 8, 27), playable: true));
    expect(find.byKey(const ValueKey('calendar-new-2')), findsOneWidget);
    expect(find.text('New today'), findsOneWidget);
  });

  testWidgets('a card with no artwork still lays out', (tester) async {
    await _pump(tester,
        _entry(id: '3', airDate: DateTime(2026, 8, 20), playable: true));
    expect(tester.takeException(), isNull);
    expect(find.byType(CalendarArtwork), findsOneWidget);
  });

  /// Mounts a card, taps the target keyed [tapKey] and returns the paths
  /// pushed to the detail or player routes.
  Future<List<String>> tapAndCollect(
    WidgetTester tester,
    ItemSummary entry,
    String tapKey,
  ) async {
    final pushed = <String>[];
    await pumpDetailScreen(
      tester,
      Scaffold(
        body: CalendarCard(
            entry: entry, today: DateTime(2026, 8, 27), imageHeight: 150),
      ),
      [ScriptedDetailSource(detailOf: (ref) => throw StateError('offline'))],
      size: const Size(1600, 900),
      routes: [
        for (final path in [
          '/s/:sourceId/episode/:itemId',
          '/s/:sourceId/player/:itemId',
        ])
          GoRoute(
            path: path,
            builder: (context, state) {
              pushed.add(state.uri.path);
              return const Scaffold(body: SizedBox.shrink());
            },
          ),
      ],
    );
    await tester.tap(find.byKey(ValueKey(tapKey)));
    for (var i = 0; i < 250 && pushed.isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    return pushed;
  }

  testWidgets('tapping the body opens detail, not the player', (tester) async {
    final entry =
        _entry(id: '9', airDate: DateTime(2026, 8, 20), playable: true);

    final pushed = await tapAndCollect(tester, entry, 'calendar-card-9');

    expect(pushed, hasLength(1));
    expect(pushed.single, contains('/episode/9'));
    expect(pushed.single, isNot(contains('/player/')));
  });

  testWidgets('tapping play opens the player, not detail', (tester) async {
    final entry =
        _entry(id: '10', airDate: DateTime(2026, 8, 20), playable: true);

    final pushed = await tapAndCollect(tester, entry, 'calendar-play-10');

    expect(pushed, hasLength(1));
    expect(pushed.single, contains('/player/10'));
    expect(pushed.single, isNot(contains('/episode/')));
  });
}
