import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/startup/startup_error_app.dart';

void main() {
  group('StartupErrorApp', () {
    testWidgets('alreadyRunning names the actual problem and the fix',
        (tester) async {
      await tester.pumpWidget(
        StartupErrorApp.alreadyRunning(Exception('lock failed')),
      );

      expect(find.text('Mydia Player is already running'), findsOneWidget);
      expect(
        find.textContaining('Quit it, then reopen this one'),
        findsOneWidget,
      );
      expect(find.textContaining('lock failed'), findsOneWidget);
    });

    testWidgets('generic surfaces the underlying error text', (tester) async {
      await tester.pumpWidget(
        StartupErrorApp.generic(Exception('disk is on fire')),
      );

      expect(find.text("Mydia Player couldn't start"), findsOneWidget);
      expect(find.textContaining('disk is on fire'), findsOneWidget);
    });

    testWidgets('always renders a MaterialApp, never a blank screen',
        (tester) async {
      await tester.pumpWidget(
        StartupErrorApp.generic(Exception('boom')),
      );

      expect(find.byType(MaterialApp), findsOneWidget);
      expect(find.byType(Scaffold), findsOneWidget);
    });
  });
}
