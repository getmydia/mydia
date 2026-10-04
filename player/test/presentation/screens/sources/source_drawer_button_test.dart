import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/presentation/screens/sources/source_library_screen.dart';
import 'package:player/presentation/screens/sources/source_search_screen.dart';
import 'package:player/presentation/widgets/app_shell.dart';
import 'package:player/presentation/widgets/source_artwork.dart';

import 'fake_media_source.dart';

/// Mounts [screen] the way the narrow shell does: inside the Scaffold that
/// owns the drawer, keyed with [AppShell.scaffoldKey]. With [pushed] the
/// screen is pushed over a first route, so it can pop.
Future<void> _pumpInShell(
  WidgetTester tester,
  Widget screen, {
  bool pushed = false,
}) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [
      mediaSourceProvider(fakeSourceId).overrideWithValue(FakeMediaSource()),
      sourceArtworkProvider.overrideWith((ref, key) async => null),
    ],
    child: MaterialApp(
      home: Scaffold(
        key: AppShell.scaffoldKey,
        drawer: const Drawer(child: Text('drawer-body')),
        body: pushed
            ? Builder(
                builder: (context) => TextButton(
                  onPressed: () => Navigator.of(context)
                      .push(MaterialPageRoute<void>(builder: (_) => screen)),
                  child: const Text('open'),
                ),
              )
            : screen,
      ),
    ),
  ));
  await tester.pumpAndSettle();
  if (pushed) {
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }
}

const _drawerButton = Key('source-open-drawer');

void main() {
  testWidgets('a library opened from the drawer offers the drawer',
      (tester) async {
    await _pumpInShell(
        tester, const SourceLibraryScreen(library: FakeMediaSource.movies));
    expect(find.byKey(_drawerButton), findsOneWidget);

    await tester.tap(find.byKey(_drawerButton));
    await tester.pumpAndSettle();
    expect(find.text('drawer-body'), findsOneWidget);
  });

  testWidgets('search opened from the drawer offers the drawer',
      (tester) async {
    await _pumpInShell(
        tester, const SourceSearchScreen(sourceId: fakeSourceId));
    expect(find.byKey(_drawerButton), findsOneWidget);
  });

  testWidgets('a pushed library shows back, not the drawer', (tester) async {
    await _pumpInShell(
      tester,
      const SourceLibraryScreen(library: FakeMediaSource.movies),
      pushed: true,
    );
    expect(find.byKey(_drawerButton), findsNothing);
    expect(find.byType(BackButton), findsOneWidget);
  });

  testWidgets('no drawer button outside the narrow shell', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        mediaSourceProvider(fakeSourceId).overrideWithValue(FakeMediaSource()),
        sourceArtworkProvider.overrideWith((ref, key) async => null),
      ],
      child: const MaterialApp(
        home: SourceLibraryScreen(library: FakeMediaSource.movies),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.byKey(_drawerButton), findsNothing);
  });
}
