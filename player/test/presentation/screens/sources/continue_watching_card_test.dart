import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/core/theme/colors.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/presentation/screens/sources/continue_watching_card.dart';
import 'package:player/presentation/widgets/source_artwork.dart';

import 'fake_media_source.dart';

ItemSummary _item({int duration = 3600, int progress = 2280}) => ItemSummary(
      ref: const ItemRef(
        sourceId: fakeSourceId,
        kind: ItemKind.movie,
        externalId: 'night-ferry',
      ),
      title: 'Night Ferry',
      durationSeconds: duration,
      userState: UserState(watched: false, progressSeconds: progress),
    );

Future<void> _pump(
  WidgetTester tester,
  ItemSummary item, {
  VoidCallback? onTap,
  void Function(BuildContext)? onContextMenu,
}) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [
      sourceArtworkProvider.overrideWith((ref, key) async => null),
      mediaSourceProvider(fakeSourceId).overrideWithValue(FakeMediaSource()),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: Center(
          child: ContinueWatchingCard(
            item: item,
            onTap: onTap ?? () {},
            onContextMenu: onContextMenu,
          ),
        ),
      ),
    ),
  ));
  await tester.pump();
}

void main() {
  testWidgets('shows the title, progress and time left', (tester) async {
    await _pump(tester, _item());

    expect(find.text('Night Ferry'), findsOneWidget);
    expect(find.text('22m left'), findsOneWidget);
    final bar = tester.widget<LinearProgressIndicator>(
      find.byKey(const Key('continue-card-progress')),
    );
    expect(bar.value, closeTo(0.633, 0.001));
    expect(bar.color, AppColors.primary);
    expect(
      tester.getSize(find.byType(ContinueWatchingCard)).width,
      ContinueWatchingCard.artSize.width,
    );
  });

  ItemSummary episode() => const ItemSummary(
        ref: ItemRef(
          sourceId: fakeSourceId,
          kind: ItemKind.episode,
          externalId: 'saltmarsh-2',
        ),
        title: 'The Low Tide',
        showTitle: 'Saltmarsh',
        subtitle: 'S1 · E2',
        durationSeconds: 3600,
        userState: UserState(watched: false, progressSeconds: 600),
      );

  testWidgets('an episode shows its series and its place; a movie one line',
      (tester) async {
    await _pump(tester, episode());
    expect(find.text('Saltmarsh'), findsOneWidget);
    expect(find.text('S1 · E2'), findsOneWidget);
    expect(find.text('The Low Tide'), findsNothing);

    await _pump(tester, _item());
    expect(find.text('Night Ferry'), findsOneWidget);
    expect(find.text('S1 · E2'), findsNothing);
  });

  testWidgets('the trailing label renders when given and not otherwise',
      (tester) async {
    await _pump(tester, _item());
    expect(find.text('Server a'), findsNothing);

    await tester.pumpWidget(ProviderScope(
      overrides: [
        sourceArtworkProvider.overrideWith((ref, key) async => null),
        mediaSourceProvider(fakeSourceId).overrideWithValue(FakeMediaSource()),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: ContinueWatchingCard(
              item: _item(),
              onTap: () {},
              trailingLabel: 'Server a +2',
            ),
          ),
        ),
      ),
    ));
    await tester.pump();
    expect(find.text('Server a +2'), findsOneWidget);
  });

  testWidgets('scaled text up to 1.3 does not overflow', (tester) async {
    for (final (item, label) in [
      (episode(), null),
      (_item(), null),
      (episode(), 'A Rather Long Server Name +12'),
      (_item(), 'A Rather Long Server Name +12'),
    ]) {
      await tester.pumpWidget(ProviderScope(
        overrides: [
          sourceArtworkProvider.overrideWith((ref, key) async => null),
          mediaSourceProvider(fakeSourceId)
              .overrideWithValue(FakeMediaSource()),
        ],
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.3)),
            child: child!,
          ),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                height: ContinueWatchingCard.height,
                child: ContinueWatchingCard(
                    item: item, onTap: () {}, trailingLabel: label),
              ),
            ),
          ),
        ),
      ));
      await tester.pump();
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('time left rolls over to hours', (tester) async {
    await _pump(tester, _item(duration: 7200, progress: 3360));
    expect(find.text('1h 4m left'), findsOneWidget);
  });

  testWidgets('tap and long press reach their callbacks', (tester) async {
    var taps = 0;
    var menus = 0;
    await _pump(tester, _item(),
        onTap: () => taps++, onContextMenu: (_) => menus++);

    await tester.tap(find.byType(ContinueWatchingCard));
    await tester.longPress(find.byType(ContinueWatchingCard));

    expect(taps, 1);
    expect(menus, 1);
  });
}
