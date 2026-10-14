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
