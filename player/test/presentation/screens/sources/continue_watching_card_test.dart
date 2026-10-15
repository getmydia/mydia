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

  testWidgets('an episode shows its series, its place and its title',
      (tester) async {
    await _pump(tester, episode());
    expect(find.text('Saltmarsh'), findsOneWidget);
    expect(find.text('S1 · E2 · The Low Tide'), findsOneWidget);

    await _pump(tester, _item());
    expect(find.text('Night Ferry'), findsOneWidget);
    expect(find.textContaining('S1 · E2'), findsNothing);
  });

  testWidgets('an episode without a show title keeps its place in the caption',
      (tester) async {
    await _pump(
      tester,
      const ItemSummary(
        ref: ItemRef(
          sourceId: fakeSourceId,
          kind: ItemKind.episode,
          externalId: 'saltmarsh-2',
        ),
        title: 'The Low Tide',
        subtitle: 'S1 · E2',
        durationSeconds: 3600,
        userState: UserState(watched: false, progressSeconds: 600),
      ),
    );
    expect(find.text('The Low Tide'), findsOneWidget);
    expect(find.text('S1 · E2'), findsOneWidget);
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

  Future<void> pumpScaled(
    WidgetTester tester,
    ItemSummary item, {
    String? label,
    double scale = 1.0,
    bool fixedHeight = false,
  }) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sourceArtworkProvider.overrideWith((ref, key) async => null),
        mediaSourceProvider(fakeSourceId).overrideWithValue(FakeMediaSource()),
      ],
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: Builder(
              builder: (context) {
                final card = ContinueWatchingCard(
                  item: item,
                  onTap: () {},
                  trailingLabel: label,
                );
                if (!fixedHeight) return card;
                return SizedBox(
                  height: ContinueWatchingCard.heightFor(
                    context,
                    hasCaption: ContinueWatchingCard.hasCaptionFor(
                      item,
                      trailingLabel: label,
                    ),
                    hasTimeLeft: ContinueWatchingCard.hasTimeLeftFor(item),
                  ),
                  child: card,
                );
              },
            ),
          ),
        ),
      ),
    ));
    await tester.pump();
  }

  testWidgets('the body ends 12 px under the progress row, movie and episode',
      (tester) async {
    // A card with no duration shows no time-left label and reserves no line
    // for it.
    final noDuration = _item(duration: 0, progress: 0);
    expect(ContinueWatchingCard.hasTimeLeftFor(noDuration), isFalse);
    for (final item in [_item(), episode(), noDuration]) {
      // Sized the way a rail sizes it, so the gap below the progress row is
      // exactly the body padding only if heightFor matches the content.
      await pumpScaled(tester, item, fixedHeight: true);
      final cardBottom =
          tester.getBottomLeft(find.byType(ContinueWatchingCard)).dy;
      final progressRow = find.ancestor(
        of: find.byKey(const Key('continue-card-progress')),
        matching: find.byType(Row),
      );
      expect(cardBottom - tester.getBottomLeft(progressRow.last).dy,
          closeTo(12, 0.01));
    }
  });

  testWidgets('an episode card is taller than a movie card by its caption',
      (tester) async {
    await pumpScaled(tester, _item());
    final context = tester.element(find.byType(ContinueWatchingCard));
    expect(
      ContinueWatchingCard.heightFor(context, hasCaption: true),
      greaterThan(ContinueWatchingCard.heightFor(context, hasCaption: false)),
    );
    expect(ContinueWatchingCard.heightFor(context, hasCaption: true),
        lessThan(232));
  });

  testWidgets('scaled text up to 2.0 does not overflow', (tester) async {
    for (final scale in [1.3, 2.0]) {
      for (final (item, label) in [
        (episode(), null),
        (_item(), null),
        (episode(), 'A Rather Long Server Name +12'),
        (_item(), 'A Rather Long Server Name +12'),
      ]) {
        await pumpScaled(tester, item,
            label: label, scale: scale, fixedHeight: true);
        expect(tester.takeException(), isNull);
      }
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
