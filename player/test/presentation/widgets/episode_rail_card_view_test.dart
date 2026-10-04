import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/detail/detail_target.dart';
import 'package:player/domain/detail/detail_views.dart';
import 'package:player/presentation/screens/detail/detail_actions.dart';
import 'package:player/presentation/widgets/episode_download_button.dart';
import 'package:player/presentation/widgets/episode_rail_card.dart';

import '../../test_utils/mock_network_images.dart';

const _episode = EpisodeView(
  target: MydiaTarget(DetailKind.episode, 'e1'),
  showTitle: 'Invented Series',
  seasonNumber: 1,
  episodeNumber: 2,
  title: 'Lantern Rain',
);

Future<void> _pump(
  WidgetTester tester, {
  Future<void> Function(EpisodeWatchedAction)? onWatchedAction,
}) async {
  await mockNetworkImages(() async {
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: EpisodeRailCard(
            episode: _episode,
            onWatchedAction: onWatchedAction,
          ),
        ),
      ),
    ));
  });
}

void main() {
  testWidgets('no Mydia episode means no download button', (tester) async {
    await _pump(tester);
    expect(find.byType(EpisodeDownloadButton), findsNothing);
  });

  testWidgets('the watched menu reports through the callback', (tester) async {
    final calls = <EpisodeWatchedAction>[];
    await _pump(tester, onWatchedAction: (a) async => calls.add(a));
    await tester.tap(find.byTooltip('Episode actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mark watched'));
    await tester.pumpAndSettle();
    expect(calls, [EpisodeWatchedAction.watched]);
  });

  testWidgets('no callback means no watched menu', (tester) async {
    await _pump(tester);
    expect(find.byTooltip('Episode actions'), findsNothing);
  });
}
