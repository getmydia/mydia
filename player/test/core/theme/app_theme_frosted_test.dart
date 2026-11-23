import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:player/core/player/input_capabilities.dart';
import 'package:player/core/theme/app_theme.dart';
import 'package:player/core/theme/palette.dart';

void main() {
  final p = Palettes.projectionBooth;
  final t = AppTheme.build(p, liquid: false);
  const hairline = Color(0x14FFFFFF);
  const strong = Color(0x24FFFFFF);

  RoundedRectangleBorder rr(double r, Color side) => RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(r),
    side: BorderSide(color: side),
  );

  test('no splash in Frosted', () {
    expect(t.splashFactory, NoSplash.splashFactory);
    for (final s in [
      t.filledButtonTheme.style!,
      t.elevatedButtonTheme.style!,
      t.outlinedButtonTheme.style!,
      t.textButtonTheme.style!,
    ]) {
      expect(s.splashFactory, NoSplash.splashFactory);
    }
  });

  test('overlay resolves hover and press', () {
    final o = t.filledButtonTheme.style!.overlayColor!;
    expect(o.resolve({WidgetState.hovered}), const Color(0x0AFFFFFF));
    expect(o.resolve({WidgetState.pressed}), const Color(0x1F000000));
    expect(o.resolve({WidgetState.focused}), Colors.transparent);
  });

  test('buttons use radiusControl and set heights', () {
    for (final s in [
      t.filledButtonTheme.style!,
      t.elevatedButtonTheme.style!,
      t.outlinedButtonTheme.style!,
      t.textButtonTheme.style!,
    ]) {
      final shape = s.shape!.resolve({}) as RoundedRectangleBorder;
      expect(shape.borderRadius, BorderRadius.circular(10));
    }
    expect(
      t.filledButtonTheme.style!.minimumSize!.resolve({})!.height,
      AppTheme.primaryButtonHeight,
    );
    expect(
      t.outlinedButtonTheme.style!.minimumSize!.resolve({})!.height,
      AppTheme.secondaryButtonHeight,
    );
    expect(t.outlinedButtonTheme.style!.side!.resolve({})!.color, strong);
    expect(
      t.outlinedButtonTheme.style!.backgroundColor!.resolve({}),
      const Color(0x12FFFFFF),
    );
    final text = t.filledButtonTheme.style!.textStyle!.resolve({})!;
    expect(text.fontFamily, 'Inter');
    expect(text.fontWeight, FontWeight.w600);
    expect(text.fontSize, 15);
  });

  test('switch colors', () {
    final s = t.switchTheme;
    expect(s.thumbColor!.resolve({WidgetState.selected}), Colors.white);
    expect(s.trackColor!.resolve({WidgetState.selected}), p.primary);
    expect(s.trackColor!.resolve({}), p.border);
    expect(s.trackOutlineColor!.resolve({}), Colors.transparent);
  });

  test('checkbox radius 5', () {
    expect(
      t.checkboxTheme.shape,
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
    );
    expect(t.checkboxTheme.side!.color, strong);
  });

  test('menus and inputs', () {
    expect(t.popupMenuTheme.color, p.surfaceHigh);
    expect(t.popupMenuTheme.shape, rr(14, hairline));
    final label = t.popupMenuTheme.labelTextStyle!;
    expect(label.resolve({})!.color, p.textPrimary);
    expect(
      label.resolve({WidgetState.disabled})!.color,
      p.textPrimary.withValues(alpha: 0.38),
    );
    final i = t.inputDecorationTheme;
    expect(i.fillColor, p.surfaceLow);
    final enabled = i.enabledBorder! as OutlineInputBorder;
    expect(enabled.borderRadius, BorderRadius.circular(10));
    expect(enabled.borderSide.color, hairline);
    final focused = i.focusedBorder! as OutlineInputBorder;
    expect(focused.borderSide.color, p.primary);
    expect(focused.borderSide.width, 1.5);
  });

  test('tooltip and card', () {
    final d = t.tooltipTheme.decoration! as BoxDecoration;
    expect(d.borderRadius, BorderRadius.circular(8));
    expect(d.border, Border.all(color: hairline));
    expect(t.cardTheme.shape, rr(14, hairline));
    expect(t.cardTheme.surfaceTintColor, Colors.transparent);
    expect(t.tooltipTheme.waitDuration, isNull);
    expect(
      t.listTileTheme.shape,
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    );
  });

  test('tabular figures', () {
    expect(
      t.textTheme.bodyMedium!.fontFeatures,
      contains(const FontFeature.tabularFigures()),
    );
    expect(
      t.textTheme.labelLarge!.fontFeatures,
      contains(const FontFeature.tabularFigures()),
    );
  });

  test('InkWell surfaces dim like buttons', () {
    expect(t.highlightColor, const Color(0x1F000000));
    expect(t.hoverColor, const Color(0x0AFFFFFF));
    expect(t.splashColor, Colors.transparent);
  });

  test('icon buttons take the button press and hover overlay', () {
    final s = t.iconButtonTheme.style!;
    expect(s.splashFactory, NoSplash.splashFactory);
    expect(s.overlayColor!.resolve({WidgetState.pressed}), t.highlightColor);
    expect(s.overlayColor!.resolve({WidgetState.hovered}), t.hoverColor);
    // Null falls through to Material's focus layer.
    expect(s.overlayColor!.resolve({WidgetState.focused}), isNull);
  });

  testWidgets('Tab focus draws a 2px primary side off the television', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: t,
        home: Scaffold(
          body: Column(
            children: [
              FilledButton(onPressed: () {}, child: const Text('Play')),
              OutlinedButton(onPressed: () {}, child: const Text('Later')),
            ],
          ),
        ),
      ),
    );

    BorderSide sideOf(Type button) {
      final material = tester.widget<Material>(
        find
            .descendant(
              of: find.byType(button),
              matching: find.byType(Material),
            )
            .first,
      );
      return (material.shape! as OutlinedBorder).side;
    }

    expect(sideOf(FilledButton), BorderSide.none);
    expect(sideOf(OutlinedButton).color, strong);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(sideOf(FilledButton), BorderSide(color: p.primary, width: 2));
    expect(sideOf(OutlinedButton).color, strong);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(sideOf(FilledButton), BorderSide.none);
    expect(sideOf(OutlinedButton), BorderSide(color: p.primary, width: 2));
  }, skip: InputCapabilities.directionalPrimary);

  test('Liquid unchanged', () {
    final l = AppTheme.build(p, liquid: true);
    expect(l.iconButtonTheme.style!.splashFactory, isNull);
    final dark = ThemeData(useMaterial3: true, brightness: Brightness.dark);
    expect(l.highlightColor, dark.highlightColor);
    expect(l.hoverColor, dark.hoverColor);
    expect(l.splashColor, dark.splashColor);
    // Liquid draws no keyboard side (on a television withTvFocus does).
    if (!InputCapabilities.directionalPrimary) {
      expect(l.filledButtonTheme.style!.side, isNull);
    }
    final s = l.filledButtonTheme.style!;
    expect(s.shape!.resolve({}), isA<StadiumBorder>());
    expect(s.splashFactory, NoSplash.splashFactory);
    expect(l.textTheme.bodyMedium!.fontFeatures, isNull);
    expect(
      l.cardTheme.shape,
      RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusCard),
      ),
    );
    expect(
      l.elevatedButtonTheme.style!.shape!.resolve({}),
      isA<StadiumBorder>(),
    );
    expect(
      l.outlinedButtonTheme.style!.shape!.resolve({}),
      isA<StadiumBorder>(),
    );
  });
}
