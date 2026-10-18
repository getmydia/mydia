import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/liquid_glass/liquid_glass_support.dart';
import 'package:player/core/theme/palette.dart';
import 'package:player/presentation/widgets/glass/glass_chip.dart';
import 'package:player/presentation/widgets/glass_surface.dart';

Widget _host(Widget chip) =>
    MaterialApp(home: Scaffold(body: Center(child: chip)));

void main() {
  tearDown(() => LiquidGlassSupport.debugPlatformOverride = null);

  testWidgets('iOS and macOS: a glass capsule that toggles', (tester) async {
    LiquidGlassSupport.debugPlatformOverride = true;
    bool? last;
    await tester.pumpWidget(_host(GlassChip(
      key: const Key('chip'),
      label: const Text('Sort A'),
      selected: false,
      onSelected: (v) => last = v,
    )));
    expect(find.byType(GlassSurface), findsOneWidget);
    expect(find.byType(ChoiceChip), findsNothing);
    await tester.tap(find.byKey(const Key('chip')));
    expect(last, isTrue);
  });

  testWidgets('selected uses the prominent white glass', (tester) async {
    LiquidGlassSupport.debugPlatformOverride = true;
    await tester.pumpWidget(_host(GlassChip(
      label: const Text('Sort A'),
      selected: true,
      onSelected: (_) {},
    )));
    final surface = tester.widget<GlassSurface>(find.byType(GlassSurface));
    expect(surface.fillColor, isNotNull);
  });

  testWidgets('elsewhere single select is a ChoiceChip, multi a FilterChip',
      (tester) async {
    LiquidGlassSupport.debugPlatformOverride = false;
    await tester.pumpWidget(_host(GlassChip(
      label: const Text('Sort A'),
      selected: true,
      onSelected: (_) {},
    )));
    expect(find.byType(ChoiceChip), findsOneWidget);
    await tester.pumpWidget(_host(GlassChip(
      label: const Text('Filter B'),
      selected: false,
      multiSelect: true,
      onSelected: (_) {},
    )));
    expect(find.byType(FilterChip), findsOneWidget);
  });

  testWidgets('elsewhere the avatar reaches the chip', (tester) async {
    LiquidGlassSupport.debugPlatformOverride = false;
    await tester.pumpWidget(_host(GlassChip(
      avatar: const Icon(Icons.movie, key: Key('av')),
      label: const Text('Sort A'),
      selected: false,
      onSelected: (_) {},
    )));
    expect(find.byKey(const Key('av')), findsOneWidget);
  });

  testWidgets('glass avatar takes the label colour when selected',
      (tester) async {
    LiquidGlassSupport.debugPlatformOverride = true;
    await tester.pumpWidget(_host(GlassChip(
      avatar: const Icon(Icons.dns, key: Key('av')),
      label: const Text('Sort A'),
      selected: true,
      onSelected: (_) {},
    )));
    final context = tester.element(find.byKey(const Key('av')));
    expect(IconTheme.of(context).color, context.palette.background);
  });

  testWidgets('the semantics report selection', (tester) async {
    LiquidGlassSupport.debugPlatformOverride = true;
    await tester.pumpWidget(_host(GlassChip(
      label: const Text('Sort A'),
      selected: true,
      onSelected: (_) {},
    )));
    final data = tester.getSemantics(find.text('Sort A')).getSemanticsData();
    // ignore: deprecated_member_use
    expect(data.flagsCollection.isSelected.index, isNot(0));
    expect(data.label, 'Sort A');
  });
}
