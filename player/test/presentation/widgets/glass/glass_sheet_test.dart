import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/liquid_glass/liquid_glass_support.dart';
import 'package:player/presentation/widgets/glass/glass_popover.dart';
import 'package:player/presentation/widgets/glass/glass_sheet.dart';
import 'package:player/presentation/widgets/glass_surface.dart';

Widget _opener() => MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => showGlassSheet<void>(
                context: context,
                origin: context,
                backgroundColor: Colors.red,
                builder: (_) => const Text('Sheet body'),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );

void main() {
  tearDown(() => LiquidGlassSupport.debugPlatformOverride = null);

  testWidgets('iOS and macOS: the sheet sits on modal glass', (tester) async {
    LiquidGlassSupport.debugPlatformOverride = true;
    await tester.pumpWidget(_opener());
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('Sheet body'), findsOneWidget);
    expect(find.byType(GlassSurface), findsOneWidget);
    final sheet = tester.widget<BottomSheet>(find.byType(BottomSheet));
    expect(sheet.backgroundColor, Colors.transparent);
  });

  testWidgets('elsewhere it is the plain sheet with the caller colour',
      (tester) async {
    LiquidGlassSupport.debugPlatformOverride = false;
    await tester.pumpWidget(_opener());
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.byType(GlassSurface), findsNothing);
    final sheet = tester.widget<BottomSheet>(find.byType(BottomSheet));
    expect(sheet.backgroundColor, Colors.red);
  });

  testWidgets('popover surface: glass on Apple, Material elsewhere',
      (tester) async {
    LiquidGlassSupport.debugPlatformOverride = true;
    await tester.pumpWidget(
        const MaterialApp(home: GlassPopoverSurface(child: Text('Rows'))));
    expect(find.byType(GlassSurface), findsOneWidget);

    LiquidGlassSupport.debugPlatformOverride = false;
    await tester.pumpWidget(
        const MaterialApp(home: GlassPopoverSurface(child: Text('Rows'))));
    expect(find.byType(GlassSurface), findsNothing);
  });
}
