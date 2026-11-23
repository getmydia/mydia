// On a television the select is one focus stop that grows and takes the
// accent ring when focused, like the other house controls, and does not also
// draw its own thin ring. Select opens the menu and Back returns to it.
//
// Requires --dart-define=MYDIA_FORCE_TV=true.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:player/core/theme/app_theme.dart';
import 'package:player/core/theme/palette.dart';
import 'package:player/presentation/widgets/controls/app_select.dart';
import 'package:player/presentation/widgets/focus_emphasis.dart';

import '../../../test_utils/tv_shell_harness.dart';

void main() {
  group('AppSelect on the television tier', () {
    testWidgets('focus grows it, rings it, and Back returns to it', (
      tester,
    ) async {
      var value = 'a';
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.build(Palettes.projectionBooth, liquid: false),
          home: Scaffold(
            body: Center(
              child: StatefulBuilder(
                builder: (context, setState) => AppSelect<String>(
                  key: const Key('select'),
                  items: const [
                    AppSelectItem(value: 'a', label: 'Alpha'),
                    AppSelectItem(value: 'b', label: 'Bravo'),
                  ],
                  value: value,
                  onChanged: (v) => setState(() => value = v),
                ),
              ),
            ),
          ),
        ),
      );

      final emphasis = find.byType(FocusEmphasis);
      expect(emphasis, findsOneWidget);
      bool ringVisible() =>
          (tester
                      .widget<CustomPaint>(
                        find.descendant(
                          of: emphasis,
                          matching: find.byKey(FocusEmphasis.ringKey),
                        ),
                      )
                      .foregroundPainter!
                  as FocusEmphasisPainter)
              .visible;
      expect(ringVisible(), isFalse);

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(ringVisible(), isTrue);
      expect(
        tester
            .widget<FocusPaintScale>(find.byKey(FocusEmphasis.scaleKey))
            .scale,
        FocusSize.control.scale,
      );
      // FocusEmphasis's ring replaces the field's own.
      final field = tester.widget<Container>(find.byKey(AppSelect.fieldKey));
      expect(field.foregroundDecoration, isNull);

      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(find.text('Bravo'), findsOneWidget);

      await tester.sendKeyEvent(
        LogicalKeyboardKey.goBack,
        platform: 'web',
        physicalKey: PhysicalKeyboardKey.browserBack,
      );
      await tester.pumpAndSettle();
      expect(find.text('Bravo'), findsNothing);
      expect(value, 'a');
      expect(ringVisible(), isTrue);
    });
  }, skip: tvSkipReason);
}
