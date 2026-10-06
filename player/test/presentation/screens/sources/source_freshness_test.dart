import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/cache/freshness.dart';
import 'package:player/core/settings/settings_providers.dart';
import 'package:player/core/settings/settings_service.dart';
import 'package:player/core/sources/cache/source_keys.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/domain/detail/detail_target.dart';
import 'package:player/domain/sources/library.dart';
import 'package:player/presentation/screens/detail/detail_providers.dart';
import 'package:player/presentation/screens/sources/source_library_screen.dart';
import 'package:player/presentation/widgets/source_artwork.dart';

import '../../../test_utils/mock_auth_storage.dart';
import 'fake_media_source.dart';

void main() {
  test('source detail targets report their item key', () {
    final movie = fakeMovie(1).ref;
    expect(freshnessKeys(SourceTarget(movie)), [SourceKeys.item(movie)]);
    expect(freshnessKeys(SourceTarget(fakeShow.ref)), [
      SourceKeys.item(fakeShow.ref),
      SourceKeys.children(fakeShow.ref),
    ]);
  });

  testWidgets('the library screen shows the stale banner for its key',
      (tester) async {
    final container = ProviderContainer(overrides: [
      mediaSourceProvider(fakeSourceId).overrideWithValue(FakeMediaSource()),
      // No artwork requests: see source_library_screen_test.dart.
      sourceArtworkProvider.overrideWith((ref, key) async => null),
      coreSettingsServiceProvider
          .overrideWithValue(SettingsService(storage: MockAuthStorage())),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: SourceLibraryScreen(library: FakeMediaSource.movies),
      ),
    ));
    await tester.pumpAndSettle();

    container.read(freshnessRegistryProvider.notifier).publish(
          SourceKeys.browse(FakeMediaSource.movies, const BrowseQuery()),
          Freshness(
            fetchedAt: DateTime.now().subtract(const Duration(hours: 3)),
            isStale: true,
            refreshFailed: true,
            hasData: true,
          ),
        );
    await tester.pump();
    expect(find.byKey(const Key('freshness-banner')), findsOneWidget);
  });
}
