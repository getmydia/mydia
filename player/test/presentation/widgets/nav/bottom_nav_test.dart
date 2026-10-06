import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/navigation/sidebar_layout.dart';
import 'package:player/domain/navigation/source_nav.dart';
import 'package:player/domain/sources/library.dart';
import 'package:player/presentation/widgets/nav/bottom_nav.dart';

import '../../screens/sources/fake_capable_source.dart';
import '../../screens/sources/fake_media_source.dart';

Future<List<String>> _pump(
  WidgetTester tester, {
  bool withMovies = true,
  bool downloadSupported = true,
  bool isOffline = false,
}) async {
  final source = FakeCapableSource();
  final libraries = [
    for (final l in await source.libraries())
      if (withMovies || l.kind != LibraryKind.movies) l,
  ];
  final layout = SidebarLayout.defaults.reconcile(downloadSupported: true);
  final entries = bottomNavEntries(
    resolveSourceNav(
      layout: layout,
      source: fakeSourceId,
      capabilities: source.capabilities,
      libraries: libraries,
    ),
    downloadSupported: downloadSupported,
  );
  final navigations = <String>[];
  await tester.pumpWidget(ProviderScope(
    child: MaterialApp(
      home: Scaffold(
        bottomNavigationBar: BottomNav(
          location: '/s/${fakeSourceId.value}',
          onNavigate: navigations.add,
          entries: entries,
          isOffline: isOffline,
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return navigations;
}

void main() {
  testWidgets('shows Home, Movies, Shows, Downloads and Settings',
      (tester) async {
    final navigations = await _pump(tester);
    for (final label in ['Home', 'Movies', 'Shows', 'Downloads', 'Settings']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    await tester.tap(find.text('Movies'));
    expect(navigations, ['/s/${fakeSourceId.value}/library/movies']);
  });

  testWidgets('a source without a movies library has no Movies item',
      (tester) async {
    await _pump(tester, withMovies: false);
    expect(find.text('Movies'), findsNothing);
    expect(find.text('Shows'), findsOneWidget);
  });

  testWidgets(
      'Favorites takes the Downloads slot where downloads are '
      'unsupported', (tester) async {
    await _pump(tester, downloadSupported: false);
    expect(find.text('Downloads'), findsNothing);
    expect(find.text('Favorites'), findsOneWidget);
  });
}
