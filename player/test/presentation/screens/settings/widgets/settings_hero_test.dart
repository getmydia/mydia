import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/connection/connection_summary.dart';
import 'package:player/presentation/screens/settings/widgets/settings_hero.dart';

const _direct = ConnectionSummary(
  label: 'Connected to server',
  detail: 'Direct connection, no relay involved',
  tone: ConnectionTone.good,
);

Future<void> _pump(
  WidgetTester tester, {
  String username = 'admin',
  String serverUrl = 'mydia.local:4000',
  ConnectionSummary connection = _direct,
  String? version = '0.14.2',
  VoidCallback? onSignOut,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ListView(
          children: [
            SettingsHero(
              username: username,
              serverUrl: serverUrl,
              connection: connection,
              version: version,
              onSignOut: onSignOut ?? () {},
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('shows the username, host, and version', (tester) async {
    await _pump(tester);

    expect(find.text('admin'), findsOneWidget);
    expect(find.text('mydia.local:4000'), findsOneWidget);
    expect(find.text('0.14.2'), findsOneWidget);
  });

  testWidgets('shows the connection label from the summary', (tester) async {
    await _pump(
      tester,
      connection: const ConnectionSummary(
        label: 'Connected through a relay',
        detail: 'Traffic is passing through a relay server',
        tone: ConnectionTone.caution,
      ),
    );

    expect(find.text('Connected through a relay'), findsOneWidget);
  });

  testWidgets('falls back to a placeholder when the version is unknown',
      (tester) async {
    await _pump(tester, version: null);

    expect(find.text('0.14.2'), findsNothing);
    expect(find.text('–'), findsOneWidget);
  });

  testWidgets('an empty username reads as signed in rather than blank',
      (tester) async {
    await _pump(tester, username: '');

    expect(find.text('Signed in'), findsOneWidget);
    expect(find.byIcon(Icons.person), findsOneWidget);
  });

  testWidgets('an empty server url omits the host line entirely',
      (tester) async {
    await _pump(tester, serverUrl: '');

    expect(find.text('admin'), findsOneWidget);
    expect(find.text(''), findsNothing);
  });

  testWidgets('the avatar shows the first character of the username',
      (tester) async {
    await _pump(tester, username: 'alex');

    expect(find.text('A'), findsOneWidget);
  });

  testWidgets('sign out is reachable and reports taps', (tester) async {
    var taps = 0;
    await _pump(tester, onSignOut: () => taps++);

    await tester.tap(find.byKey(const Key('settings-sign-out')));
    await tester.pump();

    expect(taps, 1);
  });
}
