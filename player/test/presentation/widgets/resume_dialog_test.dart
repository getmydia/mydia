import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/widgets/resume_dialog.dart';

void main() {
  Future<void> pumpDialog(
    WidgetTester tester, {
    required int position,
    required int duration,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ResumeDialog(
            savedPositionSeconds: position,
            totalDurationSeconds: duration,
          ),
        ),
      ),
    );
  }

  group('ResumeDialog', () {
    testWidgets('reports the real percentage for a mid-movie position',
        (tester) async {
      await pumpDialog(tester, position: 2700, duration: 5400);

      expect(find.text('You previously watched 50% of this video.'),
          findsOneWidget);
    });

    testWidgets('does not claim 100% for an early position', (tester) async {
      // Regression: the dialog used to receive the partial HLS playlist length
      // as the duration, so any saved position read as 100%.
      await pumpDialog(tester, position: 300, duration: 5400);

      expect(find.text('You previously watched 6% of this video.'),
          findsOneWidget);
      expect(find.textContaining('100%'), findsNothing);
    });

    testWidgets('formats the resume point as hours, minutes and seconds',
        (tester) async {
      await pumpDialog(tester, position: 3725, duration: 5400);

      expect(find.textContaining('1:02:05'), findsWidgets);
    });

    testWidgets('offers both Resume and Start Over', (tester) async {
      await pumpDialog(tester, position: 2700, duration: 5400);

      expect(find.text('Resume'), findsOneWidget);
      expect(find.text('Start Over'), findsOneWidget);
    });
  });
}
