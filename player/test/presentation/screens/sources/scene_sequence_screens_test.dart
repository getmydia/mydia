/// The library, search and item screens carry the scene list a scene was
/// opened from into its item and player locations, for a source that can
/// name a scene's neighbours, and only for one.
library;

import 'package:material_ui/material_ui.dart' hide Page;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:player/core/downloads/download_providers.dart';
import 'package:player/core/router/source_detail_routes.dart';
import 'package:player/core/settings/settings_providers.dart';
import 'package:player/core/settings/settings_service.dart';
import 'package:player/core/sources/media_source.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/domain/sources/library.dart';
import 'package:player/domain/sources/playback_sequence.dart';
import 'package:player/l10n/l10n.dart';
import 'package:player/presentation/screens/detail/detail_links.dart';
import 'package:player/presentation/screens/sources/source_library_screen.dart';
import 'package:player/presentation/screens/sources/source_search_screen.dart';
import 'package:player/presentation/widgets/source_artwork.dart';

import '../../../test_utils/mock_auth_storage.dart';
import 'fake_media_source.dart';
import 'scene_sequence_links_test.dart' show FakeSceneSource, fakeScene;

const _scene = ItemRef(
  sourceId: fakeSourceId,
  kind: ItemKind.video,
  externalId: 'm3',
);

/// Serves scenes from its library and its search.
class _ScenesSource extends FakeSceneSource {
  @override
  Future<Page<ItemSummary>> browse(
    LibraryRef library,
    BrowseQuery query, {
    Cursor? cursor,
  }) async => Page(items: [for (var n = 1; n <= 5; n++) fakeScene(n)]);

  @override
  Future<List<ItemSummary>> search(String query) async => [
    for (var n = 1; n <= 5; n++) fakeScene(n),
  ];
}

/// The same scenes from a source that cannot name neighbours.
class _PlainScenesSource extends FakeMediaSource {
  @override
  Future<Page<ItemSummary>> browse(
    LibraryRef library,
    BrowseQuery query, {
    Cursor? cursor,
  }) async => Page(items: [for (var n = 1; n <= 5; n++) fakeScene(n)]);
}

/// Mounts [home] (or [initialLocation] on the real item route) and records
/// every item and player location pushed.
Future<List<String>> _pump(
  WidgetTester tester,
  MediaSource source, {
  Widget? home,
  String initialLocation = '/',
}) async {
  final pushed = <String>[];
  GoRoute record(String path) => GoRoute(
    path: path,
    builder: (_, s) {
      pushed.add(s.uri.toString());
      return const SizedBox();
    },
  );
  final router = GoRouter(
    initialLocation: initialLocation,
    routes: [
      if (home != null)
        GoRoute(path: '/', builder: (_, _) => home)
      else
        sourceItemRoute(),
      if (home != null) record('/s/:id/item/:kind/:item'),
      record('/s/:id/player/:item'),
    ],
  );
  await tester.binding.setSurfaceSize(const Size(1280, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        mediaSourceProvider(fakeSourceId).overrideWithValue(source),
        coreSettingsServiceProvider.overrideWithValue(
          SettingsService(storage: MockAuthStorage()),
        ),
        // No artwork requests: a URL keeps a spinner running and
        // pumpAndSettle never settles.
        sourceArtworkProvider.overrideWith((ref, key) async => null),
        isItemDownloadedProvider(_scene).overrideWith((ref) => false),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return pushed;
}

void main() {
  const library = SourceLibraryScreen(
    library: FakeMediaSource.movies,
    initialQuery: BrowseQuery(sortId: 'added', filterIds: {'unwatched'}),
  );

  group('library', () {
    testWidgets('a scene opens with its place in the sorted library', (
      tester,
    ) async {
      final pushed = await _pump(tester, _ScenesSource(), home: library);
      await tester.tap(find.byKey(const ValueKey('source-poster-v3')));
      await tester.pumpAndSettle();
      final opened = Uri.parse(pushed.single);
      expect(opened.path, '/s/acc1:owner:aa11/item/video/v3');
      expect(opened.queryParameters, {
        'seq': 'library',
        'seqPos': '2',
        'seqSort': 'added',
        'seqFilter': 'unwatched',
      });
    });

    testWidgets('the list view carries it too', (tester) async {
      final pushed = await _pump(tester, _ScenesSource(), home: library);
      await tester.tap(find.byKey(const Key('source-view-toggle')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('source-list-v2')));
      await tester.pumpAndSettle();
      final opened = Uri.parse(pushed.single);
      expect(opened.queryParameters['seq'], 'library');
      expect(opened.queryParameters['seqPos'], '1');
      expect(opened.queryParameters['seqSort'], 'added');
    });

    testWidgets('a source without neighbours opens today\'s location', (
      tester,
    ) async {
      final pushed = await _pump(tester, _PlainScenesSource(), home: library);
      await tester.tap(find.byKey(const ValueKey('source-poster-v3')));
      await tester.pumpAndSettle();
      expect(pushed.single, '/s/acc1:owner:aa11/item/video/v3');
    });
  });

  testWidgets('a search result opens with its query and place', (tester) async {
    final pushed = await _pump(
      tester,
      _ScenesSource(),
      home: const SourceSearchScreen(sourceId: fakeSourceId),
    );
    await tester.enterText(
      find.byKey(const Key('source-search-field')),
      ' invented ',
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('source-poster-v4')));
    await tester.pumpAndSettle();
    expect(Uri.parse(pushed.single).queryParameters, {
      'seq': 'search',
      'seqPos': '3',
      'seqQ': 'invented',
    });
  });

  testWidgets('a tap carries the query that produced the results, not newer '
      'text still debouncing', (tester) async {
    final pushed = await _pump(
      tester,
      _ScenesSource(),
      home: const SourceSearchScreen(sourceId: fakeSourceId),
    );
    final field = find.byKey(const Key('source-search-field'));
    await tester.enterText(field, 'alpha');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    // Typed, but the debounce has not run: the grid still shows "alpha".
    await tester.enterText(field, 'alphab');
    await tester.pump(const Duration(milliseconds: 100));
    // Any rebuild in the meantime (here, re-picking the kind chip) must not
    // pick up the newer text.
    await tester.tap(find.byKey(const Key('source-search-kind-all')));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byKey(const ValueKey('source-poster-v2')));
    await tester.pumpAndSettle();
    expect(Uri.parse(pushed.single).queryParameters['seqQ'], 'alpha');
  });

  group('item screen', () {
    const scene = _scene;

    testWidgets('Play forwards the sequence it was opened with', (
      tester,
    ) async {
      final location = sourceItemLocation(
        scene,
        sequence: const PlaybackSequence(
          origin: SequenceOrigin.library,
          position: 2,
        ),
      );
      final pushed = await _pump(
        tester,
        _ScenesSource(),
        initialLocation: location,
      );
      await tester.tap(find.byKey(const Key('source-item-play')));
      await tester.pumpAndSettle();
      final opened = Uri.parse(pushed.single);
      expect(opened.path, '/s/acc1:owner:aa11/player/m3');
      expect(opened.queryParameters['seq'], 'library');
      expect(opened.queryParameters['seqPos'], '2');
    });

    testWidgets('without one, Play opens today\'s player location', (
      tester,
    ) async {
      final pushed = await _pump(
        tester,
        _ScenesSource(),
        initialLocation: sourceItemLocation(scene),
      );
      await tester.tap(find.byKey(const Key('source-item-play')));
      await tester.pumpAndSettle();
      expect(
        Uri.parse(pushed.single).queryParameters.keys,
        isNot(contains('seq')),
      );
    });
  });
}
