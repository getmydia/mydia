import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/update/updaters/macos_updater.dart';
import 'package:player/presentation/screens/settings/widgets/beta_channel_row.dart';
import 'package:player/presentation/screens/settings/widgets/settings_row.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<MethodCall> calls;
  late bool hostValue;

  setUp(() {
    calls = [];
    hostValue = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(kSparkleChannel, (call) async {
      calls.add(call);
      if (call.method == 'getBetaChannel') return hostValue;
      if (call.method == 'setBetaChannel') hostValue = call.arguments as bool;
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(kSparkleChannel, null);
  });

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: BetaChannelRow())),
    );
    await tester.pumpAndSettle();
  }

  SettingsRow row(WidgetTester tester) =>
      tester.widget<SettingsRow>(find.byKey(const Key('beta-channel-switch')));

  testWidgets('starts off when the host reports opted out', (tester) async {
    await pump(tester);

    expect(row(tester).toggleValue, isFalse);
    expect(calls.map((c) => c.method), contains('getBetaChannel'));
  });

  testWidgets('reflects an existing opt-in on first build', (tester) async {
    hostValue = true;

    await pump(tester);

    expect(row(tester).toggleValue, isTrue);
  });

  testWidgets('writes the new value to the host when toggled', (tester) async {
    await pump(tester);

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    final setCall = calls.lastWhere((c) => c.method == 'setBetaChannel');
    expect(setCall.arguments, isTrue);
    expect(row(tester).toggleValue, isTrue);
  });

  testWidgets('explains that opting out does not downgrade', (tester) async {
    await pump(tester);

    expect(find.text('Include beta versions'), findsOneWidget);
    expect(
      find.textContaining('until a stable release catches up'),
      findsOneWidget,
    );
  });

  testWidgets('reverts the switch when the host rejects the write',
      (tester) async {
    // A silently-failed write would leave the switch showing a channel the
    // updater will never honor, which is worse than not moving at all.
    //
    // The write is gated behind a Completer rather than failing immediately:
    // flutter_test's mocked MethodChannel resolves an immediately-throwing
    // handler entirely within the `tester.tap()` call that triggers it (no
    // real async delay), so without a gate there is no frame at which the
    // optimistic, not-yet-confirmed value is observable at all.
    await pump(tester);
    final gate = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(kSparkleChannel, (call) async {
      if (call.method == 'getBetaChannel') return false;
      await gate.future;
      throw PlatformException(code: 'boom');
    });

    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(row(tester).toggleValue, isTrue,
        reason: 'the switch should move optimistically');

    gate.complete();
    await tester.pumpAndSettle();
    expect(row(tester).toggleValue, isFalse,
        reason: 'a rejected write must revert');
  });

  testWidgets('two failing taps settle on the host value', (tester) async {
    await pump(tester);
    // Both writes fail and the host keeps reporting false. The row must
    // converge on that, not on the inverse of whatever it last sent.
    //
    // Both writes are gated so the second tap's write genuinely overlaps the
    // first's still-pending one. Without gating, flutter_test's mocked
    // MethodChannel resolves each tap's entire write-then-catch chain inside
    // that tap's own `tester.tap()` call, so the two calls never actually
    // overlap and the race this guards against cannot occur.
    final gates = <Completer<void>>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(kSparkleChannel, (call) async {
      if (call.method == 'getBetaChannel') return false;
      final gate = Completer<void>();
      gates.add(gate);
      await gate.future;
      throw PlatformException(code: 'boom');
    });

    await tester.tap(find.byType(Switch));
    await tester.pump();
    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(gates, hasLength(2),
        reason: 'both writes must be in flight at once');

    // Resolve the writes in the order they were sent, matching the trace
    // this test guards against: the first tap's write fails, then the
    // second's.
    gates[0].complete();
    await tester.pump();
    gates[1].complete();
    await tester.pumpAndSettle();

    expect(row(tester).toggleValue, isFalse);
  });

  testWidgets('uses no em dashes in its copy', (tester) async {
    await pump(tester);

    final texts = tester.widgetList<Text>(find.byType(Text));
    for (final text in texts) {
      expect(text.data ?? '', isNot(contains('—')));
    }
  });
}
