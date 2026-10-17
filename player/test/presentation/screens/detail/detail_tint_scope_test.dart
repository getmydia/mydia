import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/media_source.dart';
import 'package:player/core/theme/ambient_tint/ambient_tint.dart';
import 'package:player/core/theme/ambient_tint/ambient_tint_colors.dart';
import 'package:player/core/theme/palette.dart';
import 'package:player/core/theme/ambient_tint/ambient_tint_providers.dart';
import 'package:player/domain/detail/detail_art.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/presentation/screens/detail/detail_tint_scope.dart';
import 'package:player/presentation/widgets/ambient_backdrop_provider.dart';
import 'package:player/presentation/widgets/source_artwork.dart';

import '../sources/fake_media_source.dart' show fakeSourceId;

const _rust = Color(0xFF9F4A2F);

class _Probe extends StatelessWidget {
  const _Probe(this.out);
  final List<AmbientTintColors> out;

  @override
  Widget build(BuildContext context) {
    out.add(AmbientTint.of(context));
    return const SizedBox();
  }
}

Future<void> _pump(
  WidgetTester tester,
  DetailArt? art,
  List<AmbientTintColors> seen, {
  List<Override> overrides = const [],
}) {
  return tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        home: DetailTintScope(art: art, child: _Probe(seen)),
      ),
    ),
  );
}

void main() {
  testWidgets('a url art resolves to its extracted tint', (tester) async {
    final seen = <AmbientTintColors>[];
    await _pump(
      tester,
      const UrlArt('https://art/night-ferry.jpg'),
      seen,
      overrides: [
        tintExtractorProvider.overrideWithValue((_) async => _rust),
      ],
    );
    await tester.pumpAndSettle();
    expect(seen.last, AmbientTintColors.fromSeed(_rust));
  });

  testWidgets('null art reads neutral', (tester) async {
    final seen = <AmbientTintColors>[];
    await _pump(tester, null, seen);
    await tester.pumpAndSettle();
    expect(seen.last, AmbientTintColors.neutralFor(Palettes.projectionBooth));
  });

  testWidgets('while pending the ambient tint above shows', (tester) async {
    final seen = <AmbientTintColors>[];
    const warm = AmbientTintColors(
      ground: Color(0xFF2A1510),
      surface: Color(0xFF2A1510),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tintExtractorProvider.overrideWithValue(
            (_) => Future.delayed(const Duration(seconds: 1), () => _rust),
          ),
        ],
        child: MaterialApp(
          home: AmbientTint(
            colors: warm,
            child: DetailTintScope(
              art: const UrlArt('https://art/night-ferry.jpg'),
              child: _Probe(seen),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(seen.last, warm);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(seen.last, AmbientTintColors.fromSeed(_rust));
  });

  testWidgets('source art resolves through its source with headers',
      (tester) async {
    final seen = <AmbientTintColors>[];
    final calls = <BackdropSource>[];
    await _pump(
      tester,
      const SourceArt(fakeSourceId, ArtworkRef('/art/m1')),
      seen,
      overrides: [
        sourceArtworkProvider.overrideWith(
          (ref, key) async => const ArtworkRequest(
            url: 'https://srv/art/m1',
            headers: {'X-Token': 'abc'},
            cacheKey: 'k1',
          ),
        ),
        tintExtractorProvider.overrideWithValue((source) async {
          calls.add(source);
          return _rust;
        }),
      ],
    );
    await tester.pumpAndSettle();
    expect(calls.single.headers, {'X-Token': 'abc'});
    expect(calls.single.imageUrl, 'https://srv/art/m1');
    expect(seen.last, AmbientTintColors.fromSeed(_rust));
  });

  testWidgets('a second scope for the same art hits the cache', (tester) async {
    var extractions = 0;
    final container = ProviderContainer(overrides: [
      tintExtractorProvider.overrideWithValue((_) async {
        extractions++;
        return _rust;
      }),
    ]);
    addTearDown(container.dispose);
    final seen = <AmbientTintColors>[];
    Future<void> mount() => tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              home: DetailTintScope(
                art: const UrlArt('https://art/night-ferry.jpg'),
                child: _Probe(seen),
              ),
            ),
          ),
        );
    await mount();
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await mount();
    await tester.pumpAndSettle();
    expect(extractions, 1);
    expect(seen.last, AmbientTintColors.fromSeed(_rust));
  });
}
