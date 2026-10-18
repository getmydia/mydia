import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/app_theme.dart';
import 'package:player/core/theme/liquid_glass/glass_style.dart';
import 'package:player/core/theme/palette.dart';

void main() {
  Future<bool> read(WidgetTester tester, ThemeData? theme) async {
    late bool value;
    await tester.pumpWidget(MaterialApp(
      theme: theme,
      home: Builder(builder: (context) {
        value = GlassStyle.of(context);
        return const SizedBox();
      }),
    ));
    // MaterialApp animates theme changes; let the swap finish.
    await tester.pumpAndSettle();
    return value;
  }

  testWidgets('reads the flag from the app theme', (tester) async {
    expect(
        await read(
            tester, AppTheme.build(Palettes.projectionBooth, liquid: true)),
        isTrue);
    expect(
        await read(
            tester, AppTheme.build(Palettes.projectionBooth, liquid: false)),
        isFalse);
  });

  testWidgets('a theme without the extension reads as Frosted', (tester) async {
    expect(await read(tester, ThemeData.dark()), isFalse);
  });

  test('darkTheme is Frosted', () {
    expect(AppTheme.darkTheme.extension<GlassStyle>()?.liquid, isFalse);
  });

  test('lerp snaps at the midpoint', () {
    const a = GlassStyle(liquid: false);
    const b = GlassStyle(liquid: true);
    expect(a.lerp(b, 0.4).liquid, isFalse);
    expect(a.lerp(b, 0.5).liquid, isTrue);
  });
}
