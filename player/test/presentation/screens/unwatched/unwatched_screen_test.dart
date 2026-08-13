import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/auth/auth_status.dart';
import 'package:player/core/cast/cast_capabilities.dart';
import 'package:player/core/cast/cast_providers.dart';
import 'package:player/core/graphql/graphql_provider.dart';
import 'package:player/presentation/screens/unwatched/unwatched_screen.dart';
import 'package:player/presentation/widgets/browse_grid.dart';
import 'package:player/presentation/widgets/media_poster.dart';
import 'package:player/presentation/widgets/watch_indicator.dart';

import '../../../test_utils/mock_network_images.dart';
import '../../../test_utils/stub_graphql_client.dart';

class _StubAuthState extends AuthStateNotifier {
  @override
  AsyncValue<AuthStatus> build() =>
      const AsyncValue.data(AuthStatus.authenticated);
}

Map<String, dynamic> _unwatchedResponse(List<Map<String, dynamic>> items) => {
      '__typename': 'Query',
      'unwatched': items,
    };

Map<String, dynamic> _unwatchedItem({
  required String id,
  required String title,
  String type = 'movie',
  int? unwatchedEpisodeCount,
  bool withWatchStatus = false,
}) =>
    {
      '__typename': 'MediaItem',
      'id': id,
      'type': type,
      'title': title,
      'year': 2026,
      'artwork': {
        '__typename': 'Artwork',
        'posterUrl': null,
        'backdropUrl': null,
        'thumbnailUrl': null,
      },
      'addedAt': '2026-07-01T00:00:00Z',
      if (withWatchStatus)
        'watchStatus': {
          '__typename': 'WatchStatus',
          'watched': false,
          'percentage': null,
          'unwatchedEpisodeCount': unwatchedEpisodeCount,
        },
    };

Future<void> pumpUnwatchedScreen(
  WidgetTester tester, {
  required StubLink link,
  Size size = const Size(1200, 900),
}) async {
  tester.view.physicalSize = size;
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
        child: const MaterialApp(home: UnwatchedScreen()),
      ),
    );
    await tester.pumpAndSettle();
  });
}

void main() {
  testWidgets('shows its title on desktop, where it previously had none',
      (tester) async {
    await pumpUnwatchedScreen(
      tester,
      link: StubLink.responses([
        _unwatchedResponse([_unwatchedItem(id: 'u-1', title: 'Unseen Movie')]),
      ]),
    );

    expect(find.text('Unwatched'), findsOneWidget);
  });

  testWidgets('renders items through the shared grid', (tester) async {
    await pumpUnwatchedScreen(
      tester,
      link: StubLink.responses([
        _unwatchedResponse([_unwatchedItem(id: 'u-1', title: 'Unseen Movie')]),
      ]),
    );

    expect(find.byType(BrowseGrid), findsOneWidget);
    expect(find.byType(MediaPoster), findsOneWidget);
    expect(find.text('Unseen Movie'), findsOneWidget);
  });

  testWidgets('keeps its empty state', (tester) async {
    await pumpUnwatchedScreen(
      tester,
      link: StubLink.responses([_unwatchedResponse([])]),
    );

    expect(find.text('All caught up!'), findsOneWidget);
  });

  testWidgets('draws an unwatched dot on a movie', (tester) async {
    // The whole chain in one assertion: the query asks for `watchStatus`, the
    // flat-list parser reads it, the screen hands it to `MediaPoster`, and the
    // indicator renders. This screen showed no watch state at all before this
    // work, which is what made it the clearest example of the gap.
    await pumpUnwatchedScreen(
      tester,
      link: StubLink.responses([
        _unwatchedResponse([
          _unwatchedItem(
              id: 'u-1', title: 'Unseen Movie', withWatchStatus: true),
        ]),
      ]),
    );

    expect(find.byKey(WatchIndicator.dotKey), findsOneWidget);
  });

  testWidgets('draws an unwatched count on a show', (tester) async {
    await pumpUnwatchedScreen(
      tester,
      link: StubLink.responses([
        _unwatchedResponse([
          _unwatchedItem(
            id: 'u-2',
            title: 'Unseen Show',
            type: 'tv_show',
            withWatchStatus: true,
            unwatchedEpisodeCount: 6,
          ),
        ]),
      ]),
    );

    expect(find.text('6'), findsOneWidget);
  });
}
