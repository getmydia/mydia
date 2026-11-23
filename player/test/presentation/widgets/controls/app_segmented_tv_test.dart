// On a television the segmented control is one focus stop that grows and
// takes the accent ring when focused, like the other house controls, and
// does not also draw its own thin ring.
//
// Requires --dart-define=MYDIA_FORCE_TV=true.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:player/core/theme/app_theme.dart';
import 'package:player/core/theme/palette.dart';
import 'package:player/presentation/widgets/controls/app_segmented.dart';
import 'package:player/presentation/widgets/focus_emphasis.dart';

import '../../../test_utils/tv_shell_harness.dart';

void main() {
  group('AppSegmented on the television tier', () {
    testWidgets('focus grows it and draws the accent ring', (tester) async {
      var value = 1;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.build(Palettes.projectionBooth, liquid: false),
          home: Scaffold(
            body: Center(
              child: StatefulBuilder(
                builder: (context, setState) => AppSegmented<int>(
                  segments: const [
                    AppSegment(value: 0, label: 'A'),
                    AppSegment(value: 1, label: 'B'),
                    AppSegment(value: 2, label: 'C'),
                  ],
                  selected: value,
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

      // FocusEmphasis's ring replaces the control's own.
      final track = tester.widget<Container>(find.byKey(AppSegmented.trackKey));
      expect(track.foregroundDecoration, isNull);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(value, 2);
      expect(ringVisible(), isTrue);
    });
  }, skip: tvSkipReason);
}
