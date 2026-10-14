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
import 'package:player/presentation/widgets/shell_rail_inset.dart';

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

  testWidgets('the ground runs under the rail, left of the padded column',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: castCapableOverrides(),
        child: MaterialApp(
          home: AmbientTint(
            colors: _warm,
            // As the shell lays a page out: padded column, inset published.
            child: ShellRailInset(
              left: 88,
              child: Padding(
                padding: const EdgeInsets.only(left: 88),
                child: DetailScreenFrame<String>(
                  target: _target,
                  value: const AsyncValue.loading(),
                  noun: 'movie',
                  onRetry: () {},
                  builder: (context, data) => const SizedBox(),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final strip = find.byWidgetPredicate(
      (w) => w is ColoredBox && w.color == _warm.ground,
    );
    expect(strip, findsWidgets);
    final rects = [
      for (final e in strip.evaluate()) tester.getRect(find.byWidget(e.widget)),
    ];
    expect(rects.any((r) => r.left == 0 && r.width == 88), isTrue);
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
