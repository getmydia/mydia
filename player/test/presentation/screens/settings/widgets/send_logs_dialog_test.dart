import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/screens/settings/widgets/send_logs_dialog.dart';

const _note = Key('diagnostics-send-logs-note');
const _row = Key('diagnostics-send-logs-note-row');
const _send = Key('diagnostics-send-logs-confirm');

Future<void> _open(
  WidgetTester tester, {
  required bool tv,
  Future<String> Function(String?)? send,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => showDialog<void>(
            context: context,
            builder: (_) => SendLogsDialog(
              directionalPrimary: tv,
              send: send ?? (_) async => 'CODE',
            ),
          ),
          child: const Text('open'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

/// Whether the focused node belongs to the widget keyed [key].
bool _focusIn(Key key) {
  final ctx = FocusManager.instance.primaryFocus?.context;
  if (ctx == null) return false;
  return find
      .descendant(
        of: find.byKey(key),
        matching: find.byElementPredicate((e) => e == ctx),
      )
      .evaluate()
      .isNotEmpty;
}

void main() {
  for (final tv in [false, true]) {
    testWidgets('Send is focused on open (tv=$tv)', (tester) async {
      await _open(tester, tv: tv);
      expect(_focusIn(_send), isTrue);
    });
  }

  testWidgets('off TV the note field is inline', (tester) async {
    await _open(tester, tv: false);
    expect(find.byKey(_note), findsOneWidget);
    expect(find.byKey(_row), findsNothing);
  });

  testWidgets('TV: row opens the field and Back returns to the row',
      (tester) async {
    await _open(tester, tv: true);
    expect(find.byKey(_row), findsOneWidget);
    expect(find.byKey(_note), findsNothing);
    expect(find.text('Add a note (optional)'), findsOneWidget);

    await tester.tap(find.byKey(_row));
    await tester.pumpAndSettle();
    expect(find.byKey(_note), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(_row), findsOneWidget);
    expect(find.byKey(_note), findsNothing);
    expect(find.byType(SendLogsDialog), findsOneWidget);
    expect(_focusIn(_row), isTrue);

    // With the row showing, Back closes the dialog as usual.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(SendLogsDialog), findsNothing);
  });

  testWidgets('TV: a written note shows in the row and is sent',
      (tester) async {
    String? sent;
    await _open(tester, tv: true, send: (n) async {
      sent = n;
      return 'CODE';
    });
    await tester.tap(find.byKey(_row));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(_note), 'stutters at start');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(find.byKey(_note), findsNothing);
    expect(find.text('stutters at start'), findsOneWidget);

    await tester.tap(find.byKey(_send));
    await tester.pumpAndSettle();
    expect(sent, 'stutters at start');
  });
}
