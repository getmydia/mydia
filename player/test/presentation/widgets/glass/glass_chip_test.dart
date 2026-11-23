import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/app_theme.dart';
import 'package:player/core/theme/liquid_glass/liquid_geometry.dart';
import 'package:player/core/theme/palette.dart';
import 'package:player/presentation/widgets/controls/press_scale.dart';
import 'package:player/presentation/widgets/focus_emphasis.dart';
import 'package:player/presentation/widgets/glass/glass_button.dart';
import 'package:player/presentation/widgets/glass/glass_chip.dart';
import 'package:player/presentation/widgets/glass_surface.dart';

Widget _host(Widget chip, {required bool liquid}) => MaterialApp(
  theme: AppTheme.build(Palettes.projectionBooth, liquid: liquid),
  home: Scaffold(body: Center(child: chip)),
);

void main() {
  testWidgets('liquid GlassChip is a 34pt capsule with a 44pt target', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        GlassChip(
          label: const Text('Sort A'),
          selected: false,
          onSelected: (_) {},
        ),
        liquid: true,
      ),
    );
    expect(
      tester.getSize(find.byType(GlassSurface)).height,
      LiquidGeometry.buttonMedium,
    );
    expect(
      tester.getSize(find.byType(GlassChip)).height,
      greaterThanOrEqualTo(LiquidGeometry.minHitTarget),
    );
  });

  testWidgets('in a 48pt chip row the glass is still 34 with a 44pt+ target', (
    tester,
  ) async {
    bool? last;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(Palettes.projectionBooth, liquid: true),
        home: Scaffold(
          body: SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: GlassChip(
                    label: const Text('Sort A'),
                    selected: false,
                    onSelected: (v) => last = v,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    expect(
      tester.getSize(find.byType(GlassSurface)).height,
      LiquidGeometry.buttonMedium,
    );
    expect(
      tester.getSize(find.byType(GlassChip)).height,
      greaterThanOrEqualTo(LiquidGeometry.minHitTarget),
    );
    final top = tester.getTopLeft(find.byType(GlassSurface));
    await tester.tapAt(top + const Offset(20, -4));
    expect(last, isTrue);
  });

  testWidgets('a large text scale grows the chip glass instead of clipping', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(Palettes.projectionBooth, liquid: true),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2.0)),
          child: child!,
        ),
        home: Scaffold(
          body: Center(
            child: GlassChip(
              label: const Text('Sort A'),
              selected: false,
              onSelected: (_) {},
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(find.byType(GlassSurface)).height,
      greaterThan(LiquidGeometry.buttonMedium),
    );
  });

  testWidgets(
    'Frosted: a large text scale grows the chip instead of clipping',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.build(Palettes.projectionBooth, liquid: false),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2.0)),
            child: child!,
          ),
          home: Scaffold(
            body: Center(
              child: GlassChip(
                label: const Text('Sort A'),
                selected: false,
                onSelected: (_) {},
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      final chip = tester.getSize(find.byType(ChoiceChip)).height;
      final label = tester.getSize(find.text('Sort A')).height;
      expect(chip, greaterThan(30));
      expect(chip, greaterThan(label));
    },
  );

  testWidgets('a liquid button and chip lay out inside IntrinsicWidth', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        IntrinsicWidth(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              GlassButton(label: 'Cancel', onPressed: () {}),
              GlassChip(
                label: const Text('Sort A'),
                selected: false,
                onSelected: (_) {},
              ),
            ],
          ),
        ),
        liquid: true,
      ),
    );
    expect(tester.takeException(), isNull);
    final glass = find.byType(GlassSurface);
    expect(tester.getSize(glass.at(0)).height, LiquidGeometry.buttonMedium);
    expect(tester.getSize(glass.at(1)).height, LiquidGeometry.buttonMedium);
    expect(
      tester.getSize(glass.at(0)).width,
      tester.getSize(glass.at(1)).width,
    );
  });

  testWidgets('Frosted chip is a 30pt outlined chip, no gold', (tester) async {
    await tester.pumpWidget(
      _host(
        GlassChip(
          label: const Text('Sort A'),
          selected: false,
          onSelected: (_) {},
        ),
        liquid: false,
      ),
    );
    expect(tester.getSize(find.byType(ChoiceChip)).height, 30);
    final chip = tester.widget<ChoiceChip>(find.byType(ChoiceChip));
    final shape = chip.shape! as RoundedRectangleBorder;
    expect(shape.borderRadius, BorderRadius.circular(8));
    final material = tester.widget<Material>(
      find
          .descendant(
            of: find.byType(ChoiceChip),
            matching: find.byType(Material),
          )
          .first,
    );
    final rendered = material.shape! as RoundedRectangleBorder;
    expect(rendered.side.color, const Color(0x24FFFFFF));
    expect(rendered.side.style, BorderStyle.solid);
    expect(rendered.borderRadius, BorderRadius.circular(8));
    expect(
      tester.getSize(find.byType(GlassChip)).height,
      greaterThanOrEqualTo(44),
    );
    expect(
      find.descendant(
        of: find.byType(FocusEmphasis),
        matching: find.byType(PressScale),
      ),
      findsOneWidget,
    );
    final ctx = tester.element(find.byType(ChoiceChip));
    expect(chip.labelStyle!.fontSize, 12.5);
    expect(chip.labelStyle!.fontWeight, FontWeight.w500);
    expect(chip.labelStyle!.color, ctx.palette.textPrimary);
    expect(chip.selectedColor, Colors.white);
    expect(chip.backgroundColor, isNot(ctx.palette.primary));
  });

  testWidgets('Frosted selected chip is white with a dark label', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        GlassChip(
          label: const Text('Sort A'),
          selected: true,
          multiSelect: true,
          onSelected: (_) {},
        ),
        liquid: false,
      ),
    );
    final chip = tester.widget<FilterChip>(find.byType(FilterChip));
    final ctx = tester.element(find.byType(FilterChip));
    expect(chip.selectedColor, Colors.white);
    expect(chip.labelStyle!.color, ctx.palette.background);
    expect(tester.getSize(find.byType(FilterChip)).height, 30);
  });

  testWidgets('Liquid Glass: a glass capsule that toggles', (tester) async {
    bool? last;
    await tester.pumpWidget(
      _host(
        GlassChip(
          key: const Key('chip'),
          label: const Text('Sort A'),
          selected: false,
          onSelected: (v) => last = v,
        ),
        liquid: true,
      ),
    );
    expect(find.byType(GlassSurface), findsOneWidget);
    expect(find.byType(ChoiceChip), findsNothing);
    await tester.tap(find.byKey(const Key('chip')));
    expect(last, isTrue);
  });

  testWidgets('selected uses the prominent white glass', (tester) async {
    await tester.pumpWidget(
      _host(
        GlassChip(
          label: const Text('Sort A'),
          selected: true,
          onSelected: (_) {},
        ),
        liquid: true,
      ),
    );
    final surface = tester.widget<GlassSurface>(find.byType(GlassSurface));
    expect(surface.fillColor, isNotNull);
  });

  testWidgets('Frosted: single select is a ChoiceChip, multi a FilterChip', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        GlassChip(
          label: const Text('Sort A'),
          selected: true,
          onSelected: (_) {},
        ),
        liquid: false,
      ),
    );
    expect(find.byType(ChoiceChip), findsOneWidget);
    await tester.pumpWidget(
      _host(
        GlassChip(
          label: const Text('Filter B'),
          selected: false,
          multiSelect: true,
          onSelected: (_) {},
        ),
        liquid: false,
      ),
    );
    expect(find.byType(FilterChip), findsOneWidget);
  });

  testWidgets('Frosted: the avatar reaches the chip', (tester) async {
    await tester.pumpWidget(
      _host(
        GlassChip(
          avatar: const Icon(Icons.movie, key: Key('av')),
          label: const Text('Sort A'),
          selected: false,
          onSelected: (_) {},
        ),
        liquid: false,
      ),
    );
    expect(find.byKey(const Key('av')), findsOneWidget);
  });

  testWidgets('glass avatar takes the label colour when selected', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        GlassChip(
          avatar: const Icon(Icons.dns, key: Key('av')),
          label: const Text('Sort A'),
          selected: true,
          onSelected: (_) {},
        ),
        liquid: true,
      ),
    );
    final context = tester.element(find.byKey(const Key('av')));
    expect(IconTheme.of(context).color, context.palette.background);
  });

  testWidgets('the semantics report selection', (tester) async {
    await tester.pumpWidget(
      _host(
        GlassChip(
          label: const Text('Sort A'),
          selected: true,
          onSelected: (_) {},
        ),
        liquid: true,
      ),
    );
    final data = tester.getSemantics(find.text('Sort A')).getSemanticsData();
    // ignore: deprecated_member_use
    expect(data.flagsCollection.isSelected.index, isNot(0));
    expect(data.label, 'Sort A');
  });
}
