import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/ambient_tint/ambient_tint.dart';
import 'package:player/core/theme/ambient_tint/ambient_tint_colors.dart';
import 'package:player/core/theme/ambient_tint/ambient_tint_providers.dart';
import 'package:player/domain/detail/detail_art.dart';
import 'package:player/domain/detail/detail_target.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/presentation/screens/detail/detail_screen_frame.dart';

import '../../../helpers/cast_test_overrides.dart';
import '../sources/fake_media_source.dart' show fakeSourceId;

const _target = SourceTarget(
  ItemRef(sourceId: fakeSourceId, kind: ItemKind.movie, externalId: 'm1'),
);
const _rust = Color(0xFF9F4A2F);
const _warm = AmbientTintColors(
  ground: Color(0xFF2A1510),
  surface: Color(0xFF2A1510),
);

Future<void> _pump(
  WidgetTester tester,
  AsyncValue<String> value,
  List<AmbientTintColors> seen,
) {
  return tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        ...castCapableOverrides(),
        tintExtractorProvider.overrideWithValue((_) async => _rust),
      ],
      child: MaterialApp(
        home: AmbientTint(
          colors: _warm,
          child: DetailScreenFrame<String>(
            target: _target,
            value: value,
            noun: 'movie',
            onRetry: () {},
            tintArt: (data) => UrlArt('https://art/$data.jpg'),
            builder: (context, data) {
              seen.add(AmbientTint.of(context));
              return const SizedBox();
            },
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('loaded data tints the content and the scaffold', (tester) async {
    final seen = <AmbientTintColors>[];
    await _pump(tester, const AsyncValue.data('night-ferry'), seen);
    await tester.pumpAndSettle();

    final expected = AmbientTintColors.fromSeed(_rust);
    expect(seen.last, expected);
    expect(tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
        expected.ground);
  });

  testWidgets('loading keeps the inherited tint', (tester) async {
    final seen = <AmbientTintColors>[];
    await _pump(tester, const AsyncValue.loading(), seen);
    await tester.pump();

    expect(find.byType(Scaffold), findsOneWidget);
    expect(tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
        _warm.ground);
  });
}
