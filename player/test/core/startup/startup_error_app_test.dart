import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/crash_reporting/startup_report_controller.dart';
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

    const buttonKey = Key('startup-report-button');

    bool buttonEnabled(WidgetTester tester) =>
        tester.widget<ButtonStyleButton>(find.byKey(buttonKey)).enabled;

    testWidgets('generic without a controller shows no report button',
        (tester) async {
      await tester.pumpWidget(StartupErrorApp.generic(Exception('boom')));

      expect(find.byKey(buttonKey), findsNothing);
    });

    testWidgets('alreadyRunning never shows a report button', (tester) async {
      await tester.pumpWidget(
        StartupErrorApp.alreadyRunning(Exception('lock failed')),
      );

      expect(find.byKey(buttonKey), findsNothing);
    });

    testWidgets('Send report sends as a tap, shows progress, then Report sent',
        (tester) async {
      final gate = Completer<bool>();
      final sends = <bool>[];
      final controller = StartupReportController(
        send: ({required bool manual}) {
          sends.add(manual);
          return gate.future;
        },
      );

      await tester.pumpWidget(
        StartupErrorApp.generic(Exception('boom'), report: controller),
      );
      expect(find.text('Send report'), findsOneWidget);
      expect(buttonEnabled(tester), isTrue);

      await tester.tap(find.byKey(buttonKey));
      await tester.pump();
      expect(find.text('Sending report'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(buttonEnabled(tester), isFalse);

      gate.complete(true);
      await tester.pumpAndSettle();
      expect(find.text('Report sent'), findsOneWidget);
      expect(buttonEnabled(tester), isFalse);
      expect(sends, [true]);
    });

    testWidgets('a failed send offers a retry', (tester) async {
      final results = [false, true];
      final controller = StartupReportController(
        send: ({required bool manual}) async => results.removeAt(0),
      );

      await tester.pumpWidget(
        StartupErrorApp.generic(Exception('boom'), report: controller),
      );
      await tester.tap(find.byKey(buttonKey));
      await tester.pumpAndSettle();
      expect(find.text("Couldn't send. Try again"), findsOneWidget);
      expect(buttonEnabled(tester), isTrue);

      await tester.tap(find.byKey(buttonKey));
      await tester.pumpAndSettle();
      expect(find.text('Report sent'), findsOneWidget);
    });

    testWidgets('opens on Report sent when the report already went out',
        (tester) async {
      final controller = StartupReportController(
        send: ({required bool manual}) async => true,
      );
      await controller.send(manual: false);

      await tester.pumpWidget(
        StartupErrorApp.generic(Exception('boom'), report: controller),
      );

      expect(find.text('Report sent'), findsOneWidget);
      expect(buttonEnabled(tester), isFalse);
    });

    testWidgets('uses no em dashes in its copy', (tester) async {
      final controller = StartupReportController(
        send: ({required bool manual}) async => false,
      );
      await tester.pumpWidget(
        StartupErrorApp.generic(Exception('boom'), report: controller),
      );
      await tester.tap(find.byKey(buttonKey));
      await tester.pumpAndSettle();

      for (final text in tester.widgetList<Text>(find.byType(Text))) {
        expect(text.data ?? '', isNot(contains('—')));
      }
    });
  });
}
