import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/auth/auth_status.dart';
import 'package:player/core/cast/cast_capabilities.dart';
import 'package:player/core/cast/cast_providers.dart';
import 'package:player/core/graphql/graphql_provider.dart';
import 'package:player/presentation/screens/continue_watching/continue_watching_screen.dart';
import 'package:player/presentation/widgets/browse_grid.dart';
import 'package:player/presentation/widgets/media_poster.dart';
import 'package:player/presentation/widgets/progress_overlay.dart';
import 'package:player/presentation/widgets/watch_indicator.dart';

import '../../../test_utils/mock_network_images.dart';
import '../../../test_utils/stub_graphql_client.dart';

class _StubAuthState extends AuthStateNotifier {
  @override
  AsyncValue<AuthStatus> build() =>
      const AsyncValue.data(AuthStatus.authenticated);
}

Map<String, dynamic> _continueWatchingResponse(
        List<Map<String, dynamic>> items) =>
    {
      '__typename': 'Query',
      'continueWatching': items,
    };

Map<String, dynamic> _continueWatchingItem({
  required String id,
  required String title,
  String type = 'movie',
  double? progressPercentage,
  bool watched = false,
}) =>
    {
      '__typename': 'ContinueWatchingItem',
      'id': id,
      'type': type,
      'title': title,
      'artwork': {
        '__typename': 'Artwork',
        'posterUrl': null,
        'backdropUrl': null,
        'thumbnailUrl': null,
      },
      'progress': progressPercentage != null
          ? {
              '__typename': 'Progress',
              'positionSeconds': 600,
              'durationSeconds': 3600,
              'percentage': progressPercentage,
              'watched': watched,
              'lastWatchedAt': '2026-07-01T00:00:00Z',
            }
          : null,
      'showId': null,
      'showTitle': null,
      'seasonNumber': null,
      'episodeNumber': null,
      'files': <dynamic>[],
    };

Future<void> pumpContinueWatchingScreen(
  WidgetTester tester, {
  required StubLink link,
}) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await mockNetworkImages(() async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          asyncGraphqlClientProvider.overrideWith(
            (ref) async => stubClient(link),
          ),
          castCapabilitiesProvider
              .overrideWithValue(const CastCapabilities.full()),
          authStateProvider.overrideWith(_StubAuthState.new),
        ],
        child: const MaterialApp(home: ContinueWatchingScreen()),
      ),
    );
    await tester.pumpAndSettle();
  });
}

void main() {
  testWidgets('renders items from a stubbed continueWatching response',
      (tester) async {
    await pumpContinueWatchingScreen(
      tester,
      link: StubLink.responses([
        _continueWatchingResponse([
          _continueWatchingItem(
            id: 'cw-1',
            title: 'In Progress Movie',
            progressPercentage: 42,
          ),
        ]),
      ]),
    );

    expect(find.text('In Progress Movie'), findsOneWidget);
    expect(find.byType(MediaPoster), findsOneWidget);
  });

  testWidgets('renders the empty state when nothing is in progress',
      (tester) async {
    await pumpContinueWatchingScreen(
      tester,
      link: StubLink.responses([
        _continueWatchingResponse([]),
      ]),
    );

    expect(find.text('Nothing in progress.'), findsOneWidget);
  });

  testWidgets('shows its title on desktop, where it previously had none',
      (tester) async {
    await pumpContinueWatchingScreen(
      tester,
      link: StubLink.responses([
        _continueWatchingResponse([
          _continueWatchingItem(id: 'cw-1', title: 'In Progress Movie'),
        ]),
      ]),
    );

    expect(find.text('Continue Watching'), findsOneWidget);
  });

  testWidgets('renders items through the shared grid', (tester) async {
    await pumpContinueWatchingScreen(
      tester,
      link: StubLink.responses([
        _continueWatchingResponse([
          _continueWatchingItem(id: 'cw-1', title: 'In Progress Movie'),
        ]),
      ]),
    );

    expect(find.byType(BrowseGrid), findsOneWidget);
  });

  testWidgets('draws a progress bar and no dot for a part-played item',
      (tester) async {
    // Every item on this rail is part-played by definition, so the bar is the
    // only mark it should ever carry.
    await pumpContinueWatchingScreen(
      tester,
      link: StubLink.responses([
        _continueWatchingResponse([
          _continueWatchingItem(
            id: 'cw-1',
            title: 'In Progress Movie',
            progressPercentage: 42,
          ),
        ]),
      ]),
    );

    expect(find.byType(ProgressOverlay), findsOneWidget);
    expect(find.byKey(WatchIndicator.dotKey), findsNothing);
  });

  testWidgets('draws nothing when an item carries no progress', (tester) async {
    await pumpContinueWatchingScreen(
      tester,
      link: StubLink.responses([
        _continueWatchingResponse([
          _continueWatchingItem(id: 'cw-2', title: 'No Progress'),
        ]),
      ]),
    );

    expect(find.byKey(WatchIndicator.dotKey), findsNothing);
  });

  testWidgets('draws no bar for an item already marked watched',
      (tester) async {
    // This is what the adapter buys. The legacy `progressPercentage` prop
    // draws a full bar for anything at 100%, watched or not. Routing through
    // `WatchStatus` applies the shared rule instead, so a watched item draws
    // nothing here exactly as it does on every other surface.
    await pumpContinueWatchingScreen(
      tester,
      link: StubLink.responses([
        _continueWatchingResponse([
          _continueWatchingItem(
            id: 'cw-3',
            title: 'Finished Movie',
            progressPercentage: 100,
            watched: true,
          ),
        ]),
      ]),
    );

    expect(find.byType(ProgressOverlay), findsNothing);
  });
}
