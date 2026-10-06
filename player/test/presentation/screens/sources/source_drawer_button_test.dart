import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/settings/settings_providers.dart';
import 'package:player/core/settings/settings_service.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/presentation/screens/sources/source_library_screen.dart';
import 'package:player/presentation/screens/sources/source_search_screen.dart';
import 'package:player/presentation/widgets/app_shell.dart';
import 'package:player/presentation/widgets/source_artwork.dart';

import '../../../test_utils/mock_auth_storage.dart';
import 'fake_media_source.dart';

/// Mounts [screen] the way the narrow shell does: inside the Scaffold that
/// owns the drawer, keyed with [AppShell.scaffoldKey]. With [pushed] the
/// screen is pushed over a first route, so it can pop.
Future<void> _pumpInShell(
  WidgetTester tester,
  Widget screen, {
  bool pushed = false,
}) async {
  // Narrow, but not so narrow the title bar overflows.
  tester.view.physicalSize = const Size(600, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    overrides: [
      _settings,
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

// A library reads its remembered sort first; real storage never answers here.
final _settings = coreSettingsServiceProvider
    .overrideWithValue(SettingsService(storage: MockAuthStorage()));

// The tooltip is the button's accessible name.
final _menu = find.byTooltip('Menu');
final _back = find.byTooltip('Back');

void main() {
  testWidgets('a library opened from the drawer offers the drawer',
      (tester) async {
    await _pumpInShell(
        tester, const SourceLibraryScreen(library: FakeMediaSource.movies));
    expect(_menu, findsOneWidget);

    await tester.tap(_menu);
    await tester.pumpAndSettle();
    expect(find.text('drawer-body'), findsOneWidget);
  });

  testWidgets('search opened from the drawer offers the drawer',
      (tester) async {
    await _pumpInShell(
        tester, const SourceSearchScreen(sourceId: fakeSourceId));
    expect(_menu, findsOneWidget);
  });

  testWidgets('a pushed library shows back, not the drawer', (tester) async {
    await _pumpInShell(
      tester,
      const SourceLibraryScreen(library: FakeMediaSource.movies),
      pushed: true,
    );
    expect(_menu, findsNothing);
    expect(_back, findsOneWidget);
  });

  testWidgets('no drawer button on the wide layout', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        _settings,
        mediaSourceProvider(fakeSourceId).overrideWithValue(FakeMediaSource()),
        sourceArtworkProvider.overrideWith((ref, key) async => null),
      ],
      child: const MaterialApp(
        home: SourceLibraryScreen(library: FakeMediaSource.movies),
      ),
    ));
    await tester.pumpAndSettle();
    expect(_menu, findsNothing);
  });
}
