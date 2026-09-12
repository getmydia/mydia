import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/widgets/focus_highlight.dart';
import 'package:player/presentation/widgets/tv_keypad.dart';

void main() {
  setUp(() {
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
  });

  tearDown(() {
    FocusManager.instance.highlightStrategy = FocusHighlightStrategy.automatic;
  });

  group('TvKeypad', () {
    testWidgets('renders all 31 valid characters and action keys',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TvKeypad(
              onCharacterPressed: (_) {},
              onDeletePressed: () {},
              onClearPressed: () {},
            ),
          ),
        ),
      );

      // Verify all 31 valid characters exist
      for (final char in TvKeypad.validCharacters) {
        expect(find.byKey(ValueKey('tv-key-$char')), findsOneWidget);
      }
      expect(TvKeypad.validCharacters.length, equals(31));

      // Verify Delete and Clear keys exist
      expect(find.byKey(const ValueKey('tv-key-delete')), findsOneWidget);
      expect(find.byKey(const ValueKey('tv-key-clear')), findsOneWidget);

      // Verify excluded ambiguous characters are NOT present
      for (final excluded in ['0', 'O', '1', 'I', 'L']) {
        expect(find.byKey(ValueKey('tv-key-$excluded')), findsNothing);
      }
    });

    testWidgets('tapping a character key calls onCharacterPressed',
        (tester) async {
      String? pressedChar;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TvKeypad(
              onCharacterPressed: (c) => pressedChar = c,
              onDeletePressed: () {},
              onClearPressed: () {},
            ),
          ),
        ),
      );

      await tester.tap(find.byKey(const ValueKey('tv-key-K')));
      await tester.pump();

      expect(pressedChar, equals('K'));
    });

    testWidgets('tapping delete and clear keys calls corresponding callbacks',
        (tester) async {
      bool deleted = false;
      bool cleared = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TvKeypad(
              onCharacterPressed: (_) {},
              onDeletePressed: () => deleted = true,
              onClearPressed: () => cleared = true,
            ),
          ),
        ),
      );

      await tester.tap(find.byKey(const ValueKey('tv-key-delete')));
      await tester.pump();
      expect(deleted, isTrue);

      await tester.tap(find.byKey(const ValueKey('tv-key-clear')));
      await tester.pump();
      expect(cleared, isTrue);
    });

    testWidgets('autofocuses first key A on row 0 col 0', (tester) async {
      String? pressedChar;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TvKeypad(
              onCharacterPressed: (c) => pressedChar = c,
              onDeletePressed: () {},
              onClearPressed: () {},
            ),
          ),
        ),
      );
      await tester.pump();

      // Find the FocusHighlight wrapping key A and check autofocus
      final focusHighlightWidgets = tester.widgetList<FocusHighlight>(
        find.ancestor(
          of: find.byKey(const ValueKey('tv-key-A')),
          matching: find.byType(FocusHighlight),
        ),
      );
      expect(focusHighlightWidgets.first.autofocus, isTrue);

      // Activating via Enter / Select on the focused key invokes callback for 'A'
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump();
      expect(pressedChar, equals('A'));
    });

    testWidgets('disables callbacks when enabled is false', (tester) async {
      String? pressedChar;
      bool deleted = false;
      bool cleared = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TvKeypad(
              enabled: false,
              onCharacterPressed: (c) => pressedChar = c,
              onDeletePressed: () => deleted = true,
              onClearPressed: () => cleared = true,
            ),
          ),
        ),
      );

      await tester.tap(find.byKey(const ValueKey('tv-key-A')));
      await tester.pump();
      expect(pressedChar, isNull);

      await tester.tap(find.byKey(const ValueKey('tv-key-delete')));
      await tester.pump();
      expect(deleted, isFalse);

      await tester.tap(find.byKey(const ValueKey('tv-key-clear')));
      await tester.pump();
      expect(cleared, isFalse);
    });
  });
}
