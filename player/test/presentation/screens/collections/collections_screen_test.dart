import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/auth/auth_status.dart';
import 'package:player/core/cast/cast_capabilities.dart';
import 'package:player/core/cast/cast_providers.dart';
import 'package:player/core/graphql/graphql_provider.dart';
import 'package:player/presentation/screens/collections/collections_screen.dart';

import '../../../test_utils/mock_network_images.dart';
import '../../../test_utils/stub_graphql_client.dart';

class _StubAuthState extends AuthStateNotifier {
  @override
  AsyncValue<AuthStatus> build() =>
      const AsyncValue.data(AuthStatus.authenticated);
}

Map<String, dynamic> _collectionsResponse(List<Map<String, dynamic>> items) => {
      '__typename': 'Query',
      'collections': items,
    };

Map<String, dynamic> _collection({
  required String id,
  required String name,
  String type = 'manual',
  String visibility = 'private',
  int itemCount = 3,
  List<String> posterPaths = const [],
}) =>
    {
      '__typename': 'Collection',
      'id': id,
      'name': name,
      'description': null,
      'type': type,
      'visibility': visibility,
      'itemCount': itemCount,
      'posterPaths': posterPaths,
    };

Future<void> pumpCollectionsScreen(
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
        child: const MaterialApp(home: CollectionsScreen()),
      ),
    );
    await tester.pumpAndSettle();
  });
}

void main() {
  testWidgets('shows its title on desktop, where it previously had none',
      (tester) async {
    await pumpCollectionsScreen(
      tester,
      link: StubLink.responses([
        _collectionsResponse([_collection(id: 'c-1', name: 'Marvel')]),
      ]),
    );

    expect(find.text('Collections'), findsOneWidget);
    expect(find.byIcon(Icons.collections_bookmark_rounded), findsOneWidget);
  });

  testWidgets('keeps its own card geometry, not the shared poster grid',
      (tester) async {
    await pumpCollectionsScreen(
      tester,
      link: StubLink.responses([
        _collectionsResponse([_collection(id: 'c-1', name: 'Marvel')]),
      ]),
    );

    final grid = tester.widget<GridView>(find.byType(GridView));
    final delegate =
        grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;

    expect(delegate.childAspectRatio, 0.85);
    expect(find.text('Marvel'), findsOneWidget);
  });

  testWidgets('keeps its empty state', (tester) async {
    await pumpCollectionsScreen(
      tester,
      link: StubLink.responses([_collectionsResponse([])]),
    );

    expect(find.text('No collections yet'), findsOneWidget);
    expect(
      find.text('Create collections in Mydia to organize your media'),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.collections_bookmark_outlined), findsOneWidget);
  });
}
