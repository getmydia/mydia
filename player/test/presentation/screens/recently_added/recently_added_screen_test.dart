import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/auth/auth_status.dart';
import 'package:player/core/cast/cast_capabilities.dart';
import 'package:player/core/cast/cast_providers.dart';
import 'package:player/core/graphql/graphql_provider.dart';
import 'package:player/presentation/screens/recently_added/recently_added_screen.dart';
import 'package:player/presentation/widgets/browse_grid.dart';
import 'package:player/presentation/widgets/media_poster.dart';

import '../../../test_utils/mock_network_images.dart';
import '../../../test_utils/stub_graphql_client.dart';

class _StubAuthState extends AuthStateNotifier {
  @override
  AsyncValue<AuthStatus> build() =>
      const AsyncValue.data(AuthStatus.authenticated);
}

Map<String, dynamic> _recentlyAddedResponse(List<Map<String, dynamic>> items) =>
    {
      '__typename': 'Query',
      'recentlyAdded': items,
    };

Map<String, dynamic> _recentlyAddedItem({
  required String id,
  required String title,
  String type = 'movie',
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
      'newEpisodeCount': null,
      'latestSeasonNumber': null,
      'latestEpisodeNumber': null,
    };

Future<void> pumpRecentlyAddedScreen(
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
        child: const MaterialApp(home: RecentlyAddedScreen()),
      ),
    );
    await tester.pumpAndSettle();
  });
}

void main() {
  testWidgets('shows its title on desktop, where it previously had none',
      (tester) async {
    await pumpRecentlyAddedScreen(
      tester,
      link: StubLink.responses([
        _recentlyAddedResponse([
          _recentlyAddedItem(id: 'r-1', title: 'New Movie'),
        ]),
      ]),
    );

    expect(find.text('Recently Added'), findsOneWidget);
    expect(find.byIcon(Icons.fiber_new_rounded), findsOneWidget);
  });

  testWidgets('renders items through the shared grid', (tester) async {
    await pumpRecentlyAddedScreen(
      tester,
      link: StubLink.responses([
        _recentlyAddedResponse([
          _recentlyAddedItem(id: 'r-1', title: 'New Movie'),
        ]),
      ]),
    );

    expect(find.byType(BrowseGrid), findsOneWidget);
    expect(find.byType(MediaPoster), findsOneWidget);
    expect(find.text('New Movie'), findsOneWidget);
  });

  testWidgets('keeps its empty state', (tester) async {
    await pumpRecentlyAddedScreen(
      tester,
      link: StubLink.responses([_recentlyAddedResponse([])]),
    );

    expect(find.text('Nothing new'), findsOneWidget);
  });
}
