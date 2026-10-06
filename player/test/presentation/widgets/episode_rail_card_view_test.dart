import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/downloads/download_providers.dart';
import 'package:player/domain/detail/detail_views.dart';
import 'package:player/presentation/screens/detail/detail_actions.dart';
import 'package:player/presentation/widgets/episode_download_button.dart';
import 'package:player/presentation/widgets/episode_rail_card.dart';

import '../../test_utils/episode_views.dart';
import '../../test_utils/mock_network_images.dart';

Future<void> _pump(
  WidgetTester tester, {
  Set<DetailFeature> features = const {},
  Future<void> Function(EpisodeWatchedAction)? onWatchedAction,
}) async {
  final episode = testEpisodeView(
    id: 'e1',
    episodeNumber: 2,
    title: 'Lantern Rain',
    features: features,
  );
  await mockNetworkImages(() async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        isItemDownloadedProvider(episode.target.ref)
            .overrideWith((ref) => false),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: EpisodeRailCard(
            episode: episode,
            onWatchedAction: onWatchedAction,
          ),
        ),
      ),
    ));
  });
}

void main() {
  testWidgets('a source that cannot download gets no download button',
      (tester) async {
    await _pump(tester);
    expect(find.byType(EpisodeDownloadButton), findsNothing);
  });

  testWidgets('a source that downloads gets one on every card', (tester) async {
    await _pump(tester, features: {DetailFeature.download});
    expect(find.byType(EpisodeDownloadButton), findsOneWidget);
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
