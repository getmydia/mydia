import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:player/core/router/app_router.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/presentation/screens/sources/source_search_screen.dart';
import 'package:player/presentation/widgets/source_artwork.dart';

import '../../presentation/screens/sources/fake_media_source.dart';

void main() {
  testWidgets('/s/:id/search?q= opens search with the query filled and run',
      (tester) async {
    final router = GoRouter(
      initialLocation: '/s/${fakeSourceId.value}/search?q=film%202',
      routes: [sourceSearchRoute()],
    );
    addTearDown(router.dispose);
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        mediaSourceProvider(fakeSourceId).overrideWithValue(FakeMediaSource()),
        sourceArtworkProvider.overrideWith((ref, key) async => null),
      ],
      child: MaterialApp.router(routerConfig: router),
    ));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();

    expect(find.byType(SourceSearchScreen), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('source-search-field')))
          .controller
          ?.text,
      'film 2',
    );
    expect(find.text('Invented Film 2'), findsOneWidget);
  });
}
