import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:player/core/sources/media_source.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/presentation/screens/all_servers/all_servers_search_screen.dart';
import 'package:player/presentation/widgets/source_artwork.dart';
import 'package:player/presentation/widgets/window_chrome/window_title_row.dart';

import '../../../domain/merged/fake_merged_source.dart';
import '../../../test_utils/toast_harness.dart';

Future<void> pump(WidgetTester tester,
    {required List<MediaSource> sources}) async {
  final router = GoRouter(routes: [
    GoRoute(path: '/', builder: (_, __) => const AllServersSearchScreen()),
  ]);
  await tester.binding.setSurfaceSize(const Size(1280, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(ProviderScope(
    overrides: [
      allServersSourcesProvider.overrideWithValue(sources),
      sourcesProvider.overrideWithValue([for (final s in sources) s.source]),
      allServersNeedSignInProvider.overrideWithValue(const []),
      sourceArtworkProvider.overrideWith((ref, key) async => null),
    ],
    child: MaterialApp.router(routerConfig: router, builder: toastLayerBuilder),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('sections by kind, hint names the server count', (t) async {
    final sa = fakeServer('a'), sb = fakeServer('b');
    final a = FakeMergedSource(sa, found: [
      item(sa, 'm1', title: 'Invented movie'),
      item(sa, 's1', kind: ItemKind.show, title: 'Invented show'),
    ]);
    final b = FakeMergedSource(sb, found: [item(sb, 'm2')]);
    await pump(t, sources: [a, b]);
    expect(find.text('Search 2 servers'), findsOneWidget);
    await t.enterText(find.byKey(const Key('all-search-field')), 'inv');
    await t.pump(const Duration(milliseconds: 500));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('all-search-section-movies')), findsOneWidget);
    expect(find.byKey(const Key('all-search-section-shows')), findsOneWidget);
    expect(find.byKey(const Key('all-search-section-episodes')), findsNothing);
  });

  testWidgets('the field sits in the browse bar beside the cast button',
      (t) async {
    await pump(t, sources: [
      FakeMergedSource(fakeServer('a')),
      FakeMergedSource(fakeServer('b')),
    ]);
    expect(find.byType(AppBar), findsNothing);
    expect(find.byKey(WindowTitleRow.castKey), findsOneWidget);
    expect(find.byKey(const Key('all-search-field')), findsOneWidget);
  });

  testWidgets('nothing found says so', (t) async {
    await pump(t, sources: [
      FakeMergedSource(fakeServer('e')),
      FakeMergedSource(fakeServer('f')),
    ]);
    await t.enterText(find.byKey(const Key('all-search-field')), 'zz');
    await t.pump(const Duration(milliseconds: 500));
    await t.pumpAndSettle();
    expect(find.text('Nothing found.'), findsOneWidget);
  });
}
