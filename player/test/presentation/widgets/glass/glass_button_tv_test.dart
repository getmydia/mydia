// On the television tier a focused Frosted GlassButton keeps its hairline:
// FocusEmphasis draws the focus ring outside it, so the theme's focus side
// would be a second ring inside the first.
//
// Requires --dart-define=MYDIA_FORCE_TV=true.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:player/core/theme/app_theme.dart';
import 'package:player/core/theme/palette.dart';
import 'package:player/presentation/widgets/glass/glass_button.dart';

import '../../../test_utils/tv_shell_harness.dart';

void main() {
  testWidgets('a focused Frosted GlassButton keeps the hairline', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(Palettes.projectionBooth, liquid: false),
        home: Scaffold(
          body: Center(
            child: GlassButton(label: 'All episodes', onPressed: () {}),
          ),
        ),
      ),
    );

    final style = tester
        .widget<OutlinedButton>(find.byType(OutlinedButton))
        .style!;
    const hairline = BorderSide(color: Color(0x24FFFFFF));
    expect(style.side!.resolve({}), hairline);
    expect(style.side!.resolve({WidgetState.focused}), hairline);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    final material = tester.widget<Material>(
      find
          .descendant(
            of: find.byType(OutlinedButton),
            matching: find.byType(Material),
          )
          .first,
    );
    expect((material.shape! as OutlinedBorder).side, hairline);
  }, skip: tvSkipReason != false);
}
