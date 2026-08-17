import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/auth/auth_service.dart';
import 'package:player/presentation/screens/login_screen.dart';

import '../../../test_utils/mock_auth_storage.dart';

Widget _buildTestWidget({MockAuthStorage? storage}) {
  final mockStorage = storage ?? MockAuthStorage();
  return ProviderScope(
    overrides: [
      authServiceProvider.overrideWithValue(AuthService(storage: mockStorage)),
    ],
    child: const MaterialApp(
      home: LoginScreen(),
    ),
  );
}

void main() {
  testWidgets(
      'LoginScreen renders header, segmented control, and Quick Pair tab by default',
      (tester) async {
    await tester.pumpWidget(_buildTestWidget());
    await tester.pumpAndSettle();

    // Header title
    expect(find.text('Connect to Server'), findsOneWidget);

    // Segmented tabs
    expect(find.text('Quick Pair'), findsOneWidget);
    expect(find.text('Direct Server'), findsOneWidget);

    // Quick Pair content (Claim Code input, Scan QR Code button, Connect button)
    expect(find.textContaining('Scan QR Code'), findsOneWidget);
    expect(find.widgetWithText(ElevatedButton, 'Connect'), findsOneWidget);
    expect(find.byTooltip('Paste claim code'), findsOneWidget);
  });

  testWidgets(
      'Switching to Direct Server tab displays server URL and credential fields',
      (tester) async {
    await tester.pumpWidget(_buildTestWidget());
    await tester.pumpAndSettle();

    // Tap Direct Server tab
    await tester.tap(find.text('Direct Server'));
    await tester.pumpAndSettle();

    // Check direct connection fields
    expect(find.text('Server URL'), findsOneWidget);
    expect(find.text('Username'), findsOneWidget);
    expect(find.text('Password'), findsOneWidget);
    expect(find.widgetWithText(ElevatedButton, 'Sign in'), findsOneWidget);
  });

  testWidgets(
      'Tapping network settings gear icon opens Advanced Settings overlay',
      (tester) async {
    await tester.pumpWidget(_buildTestWidget());
    await tester.pumpAndSettle();

    // Tap gear icon
    final settingsIcon = find.byTooltip('Relay & Network Settings');
    expect(settingsIcon, findsOneWidget);
    await tester.tap(settingsIcon);
    await tester.pumpAndSettle();

    // Advanced settings title & relay URL field
    expect(find.text('Advanced Settings'), findsOneWidget);
    expect(find.text('Relay URL'), findsOneWidget);
  });
}
