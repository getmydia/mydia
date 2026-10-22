import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/app_theme.dart';
import 'package:player/core/theme/liquid_glass/liquid_geometry.dart';
import 'package:player/core/theme/palette.dart';
import 'package:player/presentation/widgets/glass/glass_chip.dart';
import 'package:player/presentation/widgets/glass_surface.dart';

Widget _host(Widget chip, {required bool liquid}) => MaterialApp(
      theme: AppTheme.build(Palettes.projectionBooth, liquid: liquid),
      home: Scaffold(body: Center(child: chip)),
    );

void main() {
  testWidgets('liquid GlassChip is a 34pt capsule with a 44pt target',
      (tester) async {
    await tester.pumpWidget(_host(
      GlassChip(
          label: const Text('Sort A'), selected: false, onSelected: (_) {}),
      liquid: true,
    ));
    expect(tester.getSize(find.byType(GlassSurface)).height,
        LiquidGeometry.buttonMedium);
    expect(tester.getSize(find.byType(GlassChip)).height,
        greaterThanOrEqualTo(LiquidGeometry.minHitTarget));
  });

  testWidgets('Frosted chip keeps its Material height', (tester) async {
    await tester.pumpWidget(_host(
      GlassChip(
          label: const Text('Sort A'), selected: false, onSelected: (_) {}),
      liquid: false,
    ));
    expect(tester.getSize(find.byType(ChoiceChip)).height, 48);
  });

  testWidgets('Liquid Glass: a glass capsule that toggles', (tester) async {
    bool? last;
    await tester.pumpWidget(_host(
      GlassChip(
        key: const Key('chip'),
        label: const Text('Sort A'),
        selected: false,
        onSelected: (v) => last = v,
      ),
      liquid: true,
    ));
    expect(find.byType(GlassSurface), findsOneWidget);
    expect(find.byType(ChoiceChip), findsNothing);
    await tester.tap(find.byKey(const Key('chip')));
    expect(last, isTrue);
  });

  testWidgets('selected uses the prominent white glass', (tester) async {
    await tester.pumpWidget(_host(
      GlassChip(
        label: const Text('Sort A'),
        selected: true,
        onSelected: (_) {},
      ),
      liquid: true,
    ));
    final surface = tester.widget<GlassSurface>(find.byType(GlassSurface));
    expect(surface.fillColor, isNotNull);
  });

  testWidgets('Frosted: single select is a ChoiceChip, multi a FilterChip',
      (tester) async {
    await tester.pumpWidget(_host(
      GlassChip(
        label: const Text('Sort A'),
        selected: true,
        onSelected: (_) {},
      ),
      liquid: false,
    ));
    expect(find.byType(ChoiceChip), findsOneWidget);
    await tester.pumpWidget(_host(
      GlassChip(
        label: const Text('Filter B'),
        selected: false,
        multiSelect: true,
        onSelected: (_) {},
      ),
      liquid: false,
    ));
    expect(find.byType(FilterChip), findsOneWidget);
  });

  testWidgets('Frosted: the avatar reaches the chip', (tester) async {
    await tester.pumpWidget(_host(
      GlassChip(
        avatar: const Icon(Icons.movie, key: Key('av')),
        label: const Text('Sort A'),
        selected: false,
        onSelected: (_) {},
      ),
      liquid: false,
    ));
    expect(find.byKey(const Key('av')), findsOneWidget);
  });

  testWidgets('glass avatar takes the label colour when selected',
      (tester) async {
    await tester.pumpWidget(_host(
      GlassChip(
        avatar: const Icon(Icons.dns, key: Key('av')),
        label: const Text('Sort A'),
        selected: true,
        onSelected: (_) {},
      ),
      liquid: true,
    ));
    final context = tester.element(find.byKey(const Key('av')));
    expect(IconTheme.of(context).color, context.palette.background);
  });

  testWidgets('the semantics report selection', (tester) async {
    await tester.pumpWidget(_host(
      GlassChip(
        label: const Text('Sort A'),
        selected: true,
        onSelected: (_) {},
      ),
      liquid: true,
    ));
    final data = tester.getSemantics(find.text('Sort A')).getSemanticsData();
    // ignore: deprecated_member_use
    expect(data.flagsCollection.isSelected.index, isNot(0));
    expect(data.label, 'Sort A');
  });
}
