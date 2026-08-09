import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/screens/settings/widgets/settings_identity.dart';
import 'package:player/presentation/widgets/glass_surface.dart';

Future<void> _pump(
  WidgetTester tester, {
  String username = 'admin',
  String serverUrl = 'mydia.local:4000',
}) async {
  // No ProviderScope: the band takes plain values, so the screen stays the
  // only place that wires state.
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ListView(
          children: [
            SettingsIdentity(username: username, serverUrl: serverUrl),
          ],
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('shows the username and the server', (tester) async {
    await _pump(tester);

    expect(find.text('admin'), findsOneWidget);
    expect(find.text('mydia.local:4000'), findsOneWidget);
  });

  testWidgets('the avatar shows the first character of the username',
      (tester) async {
    await _pump(tester, username: 'alex');

    expect(find.text('A'), findsOneWidget);
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

  testWidgets('a long server url is ellipsized rather than wrapped',
      (tester) async {
    const long = 'https://a-very-long-hostname.example.internal:44300/mydia';
    await _pump(tester, serverUrl: long);

    final host = tester.widget<Text>(find.text(long));

    expect(host.maxLines, 1);
    expect(host.overflow, TextOverflow.ellipsis);
  });

  testWidgets('sits on the page background rather than on a card',
      (tester) async {
    // The whole point of replacing the hero: identity is not a panel. This
    // guards against someone re-wrapping the band in a SettingsCard.
    await _pump(tester);

    expect(find.byType(GlassSurface), findsNothing);
  });
}
