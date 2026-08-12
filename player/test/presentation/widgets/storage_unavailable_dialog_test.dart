import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/widgets/storage_unavailable_dialog.dart';

void main() {
  group('showStorageUnavailableDialog', () {
    testWidgets('tells the user the pairing will not survive a restart',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showStorageUnavailableDialog(context),
              child: const Text('open'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.byType(StorageUnavailableDialog), findsOneWidget);
      expect(
        find.textContaining('lost when you close', findRichText: true),
        findsOneWidget,
      );
    });

    testWidgets('completes when dismissed', (tester) async {
      var completed = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                await showStorageUnavailableDialog(context);
                completed = true;
              },
              child: const Text('open'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      expect(completed, isTrue);
      expect(find.byType(StorageUnavailableDialog), findsNothing);
    });
  });
}
