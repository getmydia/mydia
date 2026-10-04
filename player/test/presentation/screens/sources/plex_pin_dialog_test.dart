import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/screens/sources/plex_pin_dialog.dart';

void main() {
  late List<String> submitted;
  bool? result;

  Future<void> open(
      WidgetTester tester, Future<String?> Function(String) answer) async {
    submitted = [];
    result = null;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            result = await showPlexPinDialog(context, userName: 'Pip',
                submit: (pin) {
              submitted.add(pin);
              return answer(pin);
            });
          },
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Future<void> type(WidgetTester tester, String digits) async {
    for (final d in digits.split('')) {
      await tester.tap(find.byKey(Key('plex-pin-key-$d')));
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  testWidgets('submits after four digits and closes on success',
      (tester) async {
    await open(tester, (_) async => null);
    expect(find.text('PIN for Pip'), findsOneWidget);
    await type(tester, '1234');
    expect(submitted, ['1234']);
    expect(result, isTrue);
    expect(find.text('PIN for Pip'), findsNothing);
  });

  testWidgets('a wrong PIN shows the error, clears, and stays open',
      (tester) async {
    await open(
        tester, (pin) async => pin == '1234' ? null : 'That PIN is not right.');
    await type(tester, '0000');
    expect(find.byKey(const Key('plex-pin-error')), findsOneWidget);
    expect(find.text('PIN for Pip'), findsOneWidget);
    await type(tester, '1234');
    expect(submitted, ['0000', '1234']);
    expect(result, isTrue);
  });

  testWidgets('delete removes the last digit', (tester) async {
    await open(tester, (_) async => null);
    await type(tester, '12');
    await tester.tap(find.byKey(const Key('plex-pin-delete')));
    await type(tester, '345');
    expect(submitted, ['1345']);
  });

  testWidgets('takes digits from a hardware keyboard', (tester) async {
    await open(tester, (_) async => null);
    for (final key in [
      LogicalKeyboardKey.digit4,
      LogicalKeyboardKey.numpad3,
      LogicalKeyboardKey.digit2,
      LogicalKeyboardKey.digit1,
    ]) {
      await tester.sendKeyEvent(key);
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(submitted, ['4321']);
  });

  testWidgets('cancel answers false', (tester) async {
    await open(tester, (_) async => null);
    await tester.tap(find.byKey(const Key('plex-pin-cancel')));
    await tester.pumpAndSettle();
    expect(result, isFalse);
    expect(submitted, isEmpty);
  });
}
