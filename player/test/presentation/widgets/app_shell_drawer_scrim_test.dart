import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/liquid_glass/liquid_glass_support.dart';
import 'package:player/presentation/widgets/app_shell.dart';
import 'package:player/presentation/widgets/nav/floating_rail.dart';

Future<BuildContext> _context(WidgetTester tester,
    {bool highContrast = false}) async {
  late BuildContext captured;
  await tester.pumpWidget(MediaQuery(
    data: MediaQueryData(highContrast: highContrast),
    child: Builder(builder: (context) {
      captured = context;
      return const SizedBox();
    }),
  ));
  return captured;
}

void main() {
  tearDown(() => LiquidGlassSupport.debugOverride = null);

  testWidgets('the rail scrim is black at 0.55, 0.7 under high contrast',
      (tester) async {
    expect(FloatingRail.scrimColor(await _context(tester)),
        Colors.black.withValues(alpha: 0.55));
    expect(FloatingRail.scrimColor(await _context(tester, highContrast: true)),
        Colors.black.withValues(alpha: 0.7));
  });

  testWidgets('the drawer uses the rail scrim on Liquid Glass', (tester) async {
    LiquidGlassSupport.debugOverride = true;
    final context = await _context(tester, highContrast: true);
    expect(
        AppShell.drawerScrimColor(context), FloatingRail.scrimColor(context));
  });

  testWidgets('the drawer keeps the Material scrim elsewhere', (tester) async {
    LiquidGlassSupport.debugOverride = false;
    expect(AppShell.drawerScrimColor(await _context(tester)), isNull);
  });
}
