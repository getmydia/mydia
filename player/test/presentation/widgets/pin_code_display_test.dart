import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/widgets/pin_code_display.dart';

void main() {
  group('PinCodeDisplay', () {
    testWidgets('renders 6 slot boxes by default', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: PinCodeDisplay(code: ''),
          ),
        ),
      );

      expect(find.byKey(const ValueKey('pin-slot-0-active')), findsOneWidget);
      expect(find.byKey(const ValueKey('pin-slot-5')), findsOneWidget);
      expect(find.byKey(const ValueKey('pin-slot-6')), findsNothing);
    });

    testWidgets('displays entered characters in corresponding slots',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: PinCodeDisplay(code: 'AB3'),
          ),
        ),
      );

      expect(find.text('A'), findsOneWidget);
      expect(find.text('B'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
    });

    testWidgets('indicates active cursor on next slot to fill', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: PinCodeDisplay(code: 'AB'),
          ),
        ),
      );

      final activeSlotFinder = find.byKey(const ValueKey('pin-slot-2-active'));
      expect(activeSlotFinder, findsOneWidget);
    });

    testWidgets('applies error styling when hasError is true', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: PinCodeDisplay(code: 'ABCDEF', hasError: true),
          ),
        ),
      );

      final errorIndicatorFinder =
          find.byKey(const ValueKey('pin-code-error-state'));
      expect(errorIndicatorFinder, findsOneWidget);
    });

    testWidgets('does not show active cursor when loading', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: PinCodeDisplay(code: 'AB', isLoading: true),
          ),
        ),
      );

      expect(find.byKey(const ValueKey('pin-slot-2-active')), findsNothing);
      expect(find.byKey(const ValueKey('pin-slot-2')), findsOneWidget);
    });

    testWidgets('supports custom length', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: PinCodeDisplay(code: 'A', length: 4),
          ),
        ),
      );

      expect(find.byKey(const ValueKey('pin-slot-0')), findsOneWidget);
      expect(find.byKey(const ValueKey('pin-slot-1-active')), findsOneWidget);
      expect(find.byKey(const ValueKey('pin-slot-3')), findsOneWidget);
      expect(find.byKey(const ValueKey('pin-slot-4')), findsNothing);
    });
  });
}
