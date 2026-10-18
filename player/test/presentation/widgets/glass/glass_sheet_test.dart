import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/app_theme.dart';
import 'package:player/core/theme/palette.dart';
import 'package:player/presentation/widgets/glass/glass_popover.dart';
import 'package:player/presentation/widgets/glass/glass_sheet.dart';
import 'package:player/presentation/widgets/glass_surface.dart';

ThemeData _theme({required bool liquid}) =>
    AppTheme.build(Palettes.projectionBooth, liquid: liquid);

Widget _opener({required bool liquid}) => MaterialApp(
      theme: _theme(liquid: liquid),
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
  testWidgets('Liquid Glass: the sheet sits on modal glass', (tester) async {
    await tester.pumpWidget(_opener(liquid: true));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('Sheet body'), findsOneWidget);
    expect(find.byType(GlassSurface), findsOneWidget);
    final sheet = tester.widget<BottomSheet>(find.byType(BottomSheet));
    expect(sheet.backgroundColor, Colors.transparent);
  });

  testWidgets('Frosted: it is the plain sheet with the caller colour',
      (tester) async {
    await tester.pumpWidget(_opener(liquid: false));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.byType(GlassSurface), findsNothing);
    final sheet = tester.widget<BottomSheet>(find.byType(BottomSheet));
    expect(sheet.backgroundColor, Colors.red);
  });

  testWidgets('popover surface: glass on Liquid Glass, Material on Frosted',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: _theme(liquid: true),
      home: const GlassPopoverSurface(child: Text('Rows')),
    ));
    expect(find.byType(GlassSurface), findsOneWidget);

    await tester.pumpWidget(MaterialApp(
      theme: _theme(liquid: false),
      home: const GlassPopoverSurface(child: Text('Rows')),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(GlassSurface), findsNothing);
  });
}
