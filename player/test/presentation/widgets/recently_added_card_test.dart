import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/models/recently_added_item.dart';
import 'package:player/presentation/widgets/media_poster.dart';

void main() {
  Widget wrap(Widget child) =>
      ProviderScope(child: MaterialApp(home: Scaffold(body: child)));

  RecentlyAddedItem item(Map<String, dynamic> overrides) =>
      RecentlyAddedItem.fromJson({
        'id': 'abc',
        'type': 'tv_show',
        'title': 'The Bear',
        ...overrides,
      });

  testWidgets('names the episode when one arrived', (tester) async {
    final subject = item({
      'newEpisodeCount': 1,
      'latestSeasonNumber': 4,
      'latestEpisodeNumber': 2,
    });

    await tester.pumpWidget(
      wrap(
          MediaPoster(title: subject.title, subtitle: subject.newContentLabel)),
    );

    expect(find.text('S04E02'), findsOneWidget);
  });

  testWidgets('counts when more than one arrived', (tester) async {
    final subject = item({'newEpisodeCount': 3});

    await tester.pumpWidget(
      wrap(
          MediaPoster(title: subject.title, subtitle: subject.newContentLabel)),
    );

    expect(find.text('3 new episodes'), findsOneWidget);
  });

  testWidgets('shows no subtitle when there is no count', (tester) async {
    final subject = item({});

    await tester.pumpWidget(
      wrap(
          MediaPoster(title: subject.title, subtitle: subject.newContentLabel)),
    );

    expect(find.text('The Bear'), findsOneWidget);
    expect(find.textContaining('new episode'), findsNothing);
  });
}
