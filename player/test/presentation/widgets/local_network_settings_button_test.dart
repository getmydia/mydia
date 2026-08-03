import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/widgets/local_network_settings_button.dart';

void main() {
  group('localNetworkSettingsUri', () {
    test('points at the macOS Local Network privacy pane', () {
      final uri = localNetworkSettingsUri(isIOS: false);

      expect(uri.scheme, 'x-apple.systempreferences');
      expect(uri.toString(), contains('Privacy_LocalNetwork'));
    });

    test('points at the iOS app settings page', () {
      expect(localNetworkSettingsUri(isIOS: true).toString(), 'app-settings:');
    });
  });

  group('localNetworkSettingsFallback', () {
    test('names the macOS path', () {
      final text = localNetworkSettingsFallback(isIOS: false);

      expect(text, contains('System Settings'));
      expect(text, contains('Local Network'));
    });

    test('names the iOS path', () {
      final text = localNetworkSettingsFallback(isIOS: true);

      expect(text, contains('Settings'));
      expect(text, contains('Local Network'));
    });

    test('uses no em dashes in either wording', () {
      expect(localNetworkSettingsFallback(isIOS: false), isNot(contains('—')));
      expect(localNetworkSettingsFallback(isIOS: true), isNot(contains('—')));
    });
  });

  testWidgets('LocalNetworkSettingsButton renders a tappable action',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: LocalNetworkSettingsButton(available: true)),
    ));

    expect(
        find.byKey(const Key('local-network-settings-button')), findsOneWidget);
    expect(find.text('Open Settings'), findsOneWidget);
  });

  testWidgets('LocalNetworkSettingsButton renders nothing off Apple platforms',
      (tester) async {
    // discoveryDenied also covers Android's multicast lock failing, which no
    // settings pane fixes. Offering the button there deep-linked to an Apple
    // URL and then printed macOS instructions on a phone.
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: LocalNetworkSettingsButton(available: false)),
    ));

    expect(
        find.byKey(const Key('local-network-settings-button')), findsNothing);
    expect(find.text('Open Settings'), findsNothing);
  });

  testWidgets('the default is the real platform, which a test host never is',
      (tester) async {
    // Guards the production default: no override means no button here.
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: LocalNetworkSettingsButton()),
    ));

    expect(localNetworkSettingsAvailable(), isFalse);
    expect(
        find.byKey(const Key('local-network-settings-button')), findsNothing);
  });
}
