import 'package:material_ui/material_ui.dart';
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

  testWidgets('Frosted: surfaceHigh sheet, hairline, handle, ignores caller', (
    tester,
  ) async {
    await tester.pumpWidget(_opener(liquid: false));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.byType(GlassSurface), findsNothing);
    final sheet = tester.widget<BottomSheet>(find.byType(BottomSheet));
    expect(sheet.backgroundColor, Palettes.projectionBooth.surfaceHigh);
    expect(sheet.showDragHandle, isFalse);
    final shape = sheet.shape! as RoundedRectangleBorder;
    expect(
      shape.borderRadius,
      const BorderRadius.vertical(top: Radius.circular(20)),
    );
    expect(shape.side.color, const Color(0x14FFFFFF));
    final handle = tester.widget<Container>(find.byKey(frostedSheetHandleKey));
    expect(
      (handle.decoration! as BoxDecoration).color,
      Palettes.projectionBooth.border,
    );
    expect(tester.getSize(find.byKey(frostedSheetHandleKey)).width, 36);
    expect(tester.getSize(find.byKey(frostedSheetHandleKey)).height, 4);
  });

  testWidgets('Frosted: showDragHandle false draws no handle', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: _theme(liquid: false),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showGlassSheet<void>(
              context: context,
              showDragHandle: false,
              builder: (_) => const Text('Sheet body'),
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.byKey(frostedSheetHandleKey), findsNothing);
  });

  testWidgets('Frosted: 450 ms with the iOS curve', (tester) async {
    await tester.pumpWidget(_opener(liquid: false));
    await tester.tap(find.text('Open'));
    await tester.pump();
    final route =
        ModalRoute.of(tester.element(find.byType(BottomSheet)))!
            as ModalBottomSheetRoute<void>;
    expect(route.transitionDuration, const Duration(milliseconds: 450));
    expect(route.reverseTransitionDuration, const Duration(milliseconds: 450));
    expect(route.sheetAnimationStyle?.curve, const Cubic(0.32, 0.72, 0, 1));
    await tester.pumpAndSettle();
  });

  testWidgets('Frosted: reduced motion shows the sheet after one pump', (
    tester,
  ) async {
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: _opener(liquid: false),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pump();
    await tester.pump();
    final bottom = tester.getBottomLeft(find.byType(BottomSheet)).dy;
    expect(
      bottom,
      tester.view.physicalSize.height / tester.view.devicePixelRatio,
    );
  });

  testWidgets('popover surface: glass on Liquid Glass, Material on Frosted', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: _theme(liquid: true),
        home: const GlassPopoverSurface(child: Text('Rows')),
      ),
    );
    expect(find.byType(GlassSurface), findsOneWidget);

    await tester.pumpWidget(
      MaterialApp(
        theme: _theme(liquid: false),
        home: const GlassPopoverSurface(child: Text('Rows')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(GlassSurface), findsNothing);
  });
}
