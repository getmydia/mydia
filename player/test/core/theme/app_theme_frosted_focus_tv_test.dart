// On the television tier a focused Frosted button keeps the 3px accent ring
// of `withTvFocus`; the 2px keyboard side drawn elsewhere never stacks on it.
//
// Requires --dart-define=MYDIA_FORCE_TV=true.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:player/core/player/input_capabilities.dart';
import 'package:player/core/theme/app_theme.dart';
import 'package:player/core/theme/palette.dart';

void main() {
  final skipReason = InputCapabilities.directionalPrimary
      ? false
      : 'requires --dart-define=MYDIA_FORCE_TV=true to force '
            'InputCapabilities.directionalPrimary; CI runs it in the '
            '"Run television-tier tests" step.';

  testWidgets('focused Frosted buttons keep the 3px TV ring', (tester) async {
    final p = Palettes.projectionBooth;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(p, liquid: false),
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

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(sideOf(FilledButton), BorderSide(color: p.primary, width: 3));

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(sideOf(OutlinedButton), BorderSide(color: p.primary, width: 3));
  }, skip: skipReason != false);
}
