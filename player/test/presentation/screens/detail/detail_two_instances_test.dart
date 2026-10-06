import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:player/core/router/navigator_keys.dart';
import 'package:player/core/router/source_detail_routes.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/presentation/widgets/source_artwork.dart';

import '../../../helpers/cast_test_overrides.dart';
import '../../../test_utils/mock_network_images.dart';
import 'detail_harness.dart';

const _a = SourceId('acc1:owner:aa11');
const _b = SourceId('acc2:owner:bb22');

/// Answers every movie with [title], whatever its id.
ScriptedDetailSource _instance(SourceId id, String title) =>
    ScriptedDetailSource(
      id: id,
      detailOf: (ref) => ItemDetail(
        summary: ItemSummary(ref: ref, title: title, year: 2020),
        overview: 'Invented overview.',
      ),
    );

Future<GoRouter> _pump(WidgetTester tester, String location) async {
  await tester.binding.setSurfaceSize(const Size(1000, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final router = GoRouter(
    navigatorKey: rootNavigatorKey,
    initialLocation: location,
    routes: sourceDetailRoutes(),
  );
  await mockNetworkImages(() async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        mediaSourceProvider(_a)
            .overrideWithValue(_instance(_a, 'Alpha Harbor')),
        mediaSourceProvider(_b)
            .overrideWithValue(_instance(_b, 'Beta Orchard')),
        sourceArtworkProvider.overrideWith((ref, key) async => null),
        ...castCapableOverrides(),
      ],
      child: MaterialApp.router(routerConfig: router),
    ));
    await tester.pumpAndSettle();
  });
  return router;
}

void main() {
  testWidgets('the first instance answers its own movie 7', (tester) async {
    await _pump(tester, '/s/${_a.value}/movie/7');

    expect(find.text('Alpha Harbor'), findsOneWidget);
    expect(find.text('Beta Orchard'), findsNothing);
  });

  testWidgets('the second instance answers its own movie 7', (tester) async {
    await _pump(tester, '/s/${_b.value}/movie/7');

    expect(find.text('Beta Orchard'), findsOneWidget);
    expect(find.text('Alpha Harbor'), findsNothing);
  });

  testWidgets('moving between instances with the same id swaps the item',
      (tester) async {
    final router = await _pump(tester, '/s/${_a.value}/movie/7');

    router.go('/s/${_b.value}/movie/7');
    await mockNetworkImages(() async {
      await tester.pumpAndSettle();
    });

    expect(find.text('Beta Orchard'), findsOneWidget);
    expect(find.text('Alpha Harbor'), findsNothing);
  });
}
