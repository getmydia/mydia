import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/ambient_tint/ambient_tint.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:player/core/theme/ambient_tint/ambient_tint_colors.dart';
import 'package:player/core/theme/ambient_tint/ambient_tint_providers.dart';
import 'package:player/core/theme/app_theme.dart';
import 'package:player/core/theme/palette.dart';

final _warm = AmbientTintColors.fromSeed(const Color(0xFF9F4A2F));

class _Probe extends StatelessWidget {
  const _Probe(this.seen);
  final List<AmbientTintColors> seen;
  @override
  Widget build(BuildContext context) {
    seen.add(AmbientTint.of(context));
    return const SizedBox();
  }
}

class _Counter extends StatelessWidget {
  const _Counter(this.builds);
  final List<int> builds;
  @override
  Widget build(BuildContext context) {
    builds.add(1);
    return const SizedBox();
  }
}

Widget _app(AmbientTintColors colors, Widget child, {bool reduce = false}) =>
    MediaQuery(
      data: MediaQueryData(disableAnimations: reduce),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: AmbientTintScope(colors: colors, child: child),
      ),
    );

void main() {
  testWidgets('no ancestor reads neutral', (tester) async {
    final seen = <AmbientTintColors>[];
    await tester.pumpWidget(_Probe(seen));
    expect(seen.last, AmbientTintColors.neutralFor(Palettes.projectionBooth));
  });

  testWidgets('ShellAmbientTint ignores the tint when the preset has none',
      (tester) async {
    final seen = <AmbientTintColors>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ambientTintControllerProvider.overrideWithBuild((ref, _) => _warm),
        ],
        child: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Theme(
              data: AppTheme.build(Palettes.oledBlack, liquid: false),
              child: ShellAmbientTint(child: _Probe(seen)),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(seen.last, AmbientTintColors.neutralFor(Palettes.oledBlack));
  });

  testWidgets('lerps to the new tint over 600ms', (tester) async {
    final seen = <AmbientTintColors>[];
    final probe = _Probe(seen);
    await tester.pumpWidget(
        _app(AmbientTintColors.neutralFor(Palettes.projectionBooth), probe));
    await tester.pumpWidget(_app(_warm, probe));
    await tester.pump(const Duration(milliseconds: 300));
    expect(seen.last, isNot(_warm));
    expect(seen.last,
        isNot(AmbientTintColors.neutralFor(Palettes.projectionBooth)));
    await tester.pump(const Duration(milliseconds: 400));
    expect(seen.last, _warm);
  });

  testWidgets('reduced motion jumps straight to the tint', (tester) async {
    final seen = <AmbientTintColors>[];
    final probe = _Probe(seen);
    await tester.pumpWidget(
      _app(AmbientTintColors.neutralFor(Palettes.projectionBooth), probe,
          reduce: true),
    );
    await tester.pumpWidget(_app(_warm, probe, reduce: true));
    await tester.pump();
    expect(seen.last, _warm);
  });

  testWidgets('widgets that do not read the tint do not rebuild', (
    tester,
  ) async {
    final builds = <int>[];
    final counter = _Counter(builds);
    await tester.pumpWidget(
        _app(AmbientTintColors.neutralFor(Palettes.projectionBooth), counter));
    await tester.pumpWidget(_app(_warm, counter));
    await tester.pumpAndSettle();
    expect(builds, hasLength(1));
  });
}
