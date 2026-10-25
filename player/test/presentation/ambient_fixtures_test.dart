import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/cache/poster_cache_manager.dart';
import 'package:player/core/sources/media_source.dart' show ArtworkRequest;
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/core/theme/ambient_tint/ambient_tint.dart';
import 'package:player/core/theme/ambient_tint/ambient_tint_colors.dart';
import 'package:player/core/theme/palette.dart';
import 'package:player/core/theme/ambient_tint/ambient_tint_providers.dart';
import 'package:player/core/theme/ambient_tint/tint_extraction.dart';
import 'package:player/domain/detail/detail_target.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/l10n/l10n.dart';
import 'package:player/presentation/screens/movie/movie_detail_screen.dart';
import 'package:player/presentation/screens/sources/source_home_hero.dart';
import 'package:player/presentation/widgets/ambient_backdrop.dart';
import 'package:player/presentation/widgets/ambient_backdrop_provider.dart';
import 'package:player/presentation/widgets/source_artwork.dart';

import '../helpers/cast_test_overrides.dart';
import '../test_utils/mock_network_images.dart';
import 'screens/detail/detail_harness.dart' show ScriptedDetailSource;
import 'screens/sources/fake_media_source.dart';

/// Flat-colour artwork, one per tint family the sweep covers.
const _warm = Color(0xFF9F4A2F);
const _cool = Color(0xFF2F4A9F);
const _grey = Color(0xFF808080);

Future<MemoryImage> _png(Color color) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    const Rect.fromLTWH(0, 0, 64, 36),
    Paint()..color = color,
  );
  final image = await recorder.endRecording().toImage(64, 36);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  return MemoryImage(bytes!.buffer.asUint8List());
}

/// Runs the real [extractTint] on the fixture, whatever URL asks for it.
TintExtractor _extractorFor(Map<String, MemoryImage> fixtures, String key) =>
    (source) => extractTint(fixtures[key]!);

AmbientTintColors _expected(Color color) => resolveAmbientTint(
      color == _grey ? null : AmbientTintColors.fromSeed(color),
      Palettes.projectionBooth,
    );

/// Lets the real image decode finish (it needs the real event loop), then
/// runs the debounce and the tint tween out.
Future<void> _settleTint(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump(const Duration(milliseconds: 200));
  }
  await tester.pump(const Duration(seconds: 1));
}

/// Unmounts the tree and runs the artwork cache store's 10 s cleanup timer
/// out, which would otherwise outlive the test.
Future<void> _teardownTree(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 11));
}

void main() {
  // The artwork widgets build real cache managers, which ask path_provider for
  // directories once the event loop runs for real (see _settleTint).
  late Directory cacheDir;
  setUpAll(() {
    // An earlier file in the shared isolate may have built the managers
    // outside a mockNetworkImages zone, leaving them a real HttpClient.
    resetCacheManagersForTest();
    cacheDir = Directory.systemTemp.createTempSync('ambient_fixtures_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => cacheDir.path,
    );
  });
  tearDownAll(() {
    resetCacheManagersForTest();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    cacheDir.deleteSync(recursive: true);
  });

  const fixtures = <String, Color>{
    'warm': _warm,
    'cool': _cool,
    'grey': _grey,
  };

  for (final entry in fixtures.entries) {
    final name = entry.key;
    final color = entry.value;

    testWidgets('home hero over $name artwork resolves the expected tint',
        (tester) async {
      final images = {
        name: (await tester.runAsync(() => _png(color)))!,
      };
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      AmbientTintColors? seen;
      await mockNetworkImages(() async {
        await tester.pumpWidget(ProviderScope(
          overrides: [
            mediaSourceProvider(fakeSourceId)
                .overrideWithValue(FakeMediaSource()),
            tintExtractorProvider
                .overrideWithValue(_extractorFor(images, name)),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: ShellAmbientTint(
              child: Scaffold(
                body: Stack(
                  children: [
                    Consumer(builder: (context, ref, _) {
                      final source =
                          ref.watch(ambientBackdropControllerProvider);
                      return Positioned.fill(
                        child: AmbientBackdrop(
                          imageUrl: source.imageUrl,
                          id: source.id,
                          headers: source.headers,
                          cacheKey: source.cacheKey,
                        ),
                      );
                    }),
                    SingleChildScrollView(
                      child: Column(
                        children: [
                          const SourceHomeHero(
                            sourceId: fakeSourceId,
                            item: ItemSummary(
                              ref: ItemRef(
                                sourceId: fakeSourceId,
                                kind: ItemKind.movie,
                                externalId: 'night-ferry',
                              ),
                              title: 'Night Ferry',
                              year: 2011,
                              overview: 'A ferry crosses the saltmarsh.',
                              poster: ArtworkRef('/art/night-ferry'),
                              backdrop: ArtworkRef('/backdrop/night-ferry'),
                            ),
                          ),
                          Builder(builder: (context) {
                            seen = AmbientTint.of(context);
                            return const SizedBox();
                          }),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ));
        await tester.pump();
        await _settleTint(tester);
      });

      expect(find.text('Night Ferry'), findsOneWidget);
      expect(seen, _expected(color));
      expect(tester.takeException(), isNull);
      await _teardownTree(tester);
    });

    testWidgets('movie detail over $name artwork tints its scaffold',
        (tester) async {
      final images = {
        name: (await tester.runAsync(() => _png(color)))!,
      };
      const ref = ItemRef(
        sourceId: fakeSourceId,
        kind: ItemKind.movie,
        externalId: 'm-1',
      );
      final source = ScriptedDetailSource(
        detailOf: (ref) => ItemDetail(
          summary: ItemSummary(
            ref: ref,
            title: 'Night Ferry',
            year: 2011,
            backdrop: const ArtworkRef('/backdrop/night-ferry'),
          ),
          overview: 'A ferry crosses the saltmarsh after dark.',
        ),
      );

      await tester.binding.setSurfaceSize(const Size(1000, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await mockNetworkImages(() async {
        await tester.pumpWidget(ProviderScope(
          overrides: [
            mediaSourceProvider(source.id).overrideWithValue(source),
            // The harness maps artwork to null; this one resolves it, so the
            // screen's tintArt closure reaches the extractor.
            sourceArtworkProvider.overrideWith(
              (ref, key) async => ArtworkRequest(
                url: 'https://fake.test${key.art.path}',
                headers: const {},
                cacheKey: 'fixture|${key.art.path}',
              ),
            ),
            ...castCapableOverrides(),
            tintExtractorProvider
                .overrideWithValue(_extractorFor(images, name)),
          ],
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: MovieDetailScreen.target(target: SourceTarget(ref)),
          ),
        ));
        await tester.pump();
        await _settleTint(tester);
      });

      final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
      expect(scaffold.backgroundColor, _expected(color).ground);
      expect(find.text('Night Ferry'), findsWidgets);
      expect(tester.takeException(), isNull);
      await _teardownTree(tester);
    });
  }
}
