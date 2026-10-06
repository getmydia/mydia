// `app.dart` builds two different MaterialApps depending on whether the stored
// sources have loaded. Both must carry AppScrollBehavior: only the router one
// has scrollables today, but a loading screen that grows one later must not
// silently fall back to the stock behavior.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:player/app.dart';
import 'package:player/core/sources/mydia/bound_mydia.dart';
import 'package:player/core/sources/mydia/mydia_client.dart';
import 'package:player/core/cast/cast_capabilities.dart';
import 'package:player/core/cast/cast_providers.dart';
import 'package:player/core/cast/cast_session_manager.dart';
import 'package:player/core/graphql/graphql_provider.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/core/scroll/app_scroll_behavior.dart';

void main() {
  Future<void> pumpApp(
    WidgetTester tester, {
    required bool sourcesLoading,
  }) async {
    final container = ProviderContainer(overrides: [
      castCapabilitiesProvider.overrideWithValue(const CastCapabilities.full()),
      sourcesLoadingProvider.overrideWithValue(sourcesLoading),
      asyncGraphqlClientProvider
          .overrideWith((ref) => Completer<GraphQLClient>().future),
      asyncBoundMydiaClientProvider
          .overrideWith((ref) => Completer<MydiaClient>().future),
      castSessionProvider.overrideWith((ref) => Stream.value(null)),
      castSessionManagerProvider
          .overrideWith((ref) => Completer<CastSessionManager>().future),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MyApp(),
    ));
    await tester.pump();
  }

  void expectBehavior(WidgetTester tester) {
    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.scrollBehavior, isA<AppScrollBehavior>());
  }

  testWidgets('the loading app carries AppScrollBehavior', (tester) async {
    await pumpApp(tester, sourcesLoading: true);
    expectBehavior(tester);
  });

  testWidgets('the router app carries AppScrollBehavior', (tester) async {
    await pumpApp(tester, sourcesLoading: false);
    expectBehavior(tester);
  });
}
