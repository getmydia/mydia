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
    await pump(tester);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(kSparkleChannel, (call) async {
      if (call.method == 'getBetaChannel') return false;
      throw PlatformException(code: 'boom');
    });

    await tester.tap(find.byType(Switch));
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
