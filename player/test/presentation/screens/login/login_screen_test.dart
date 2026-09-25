import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/auth/auth_service.dart';
import 'package:player/core/layout/window_chrome_inset.dart';
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

/// Wraps [LoginScreen] the way `WindowChromeInset` would on a macOS build: a
/// `WindowChromeInsets` scope for the traffic-light reserve, plus the ambient
/// `MediaQuery.padding.top` the real widget adds for the band. Reproduced by
/// hand rather than mounting `WindowChromeInset` itself, since that widget
/// keys its platform branch off `defaultTargetPlatform`/`kIsWeb`, which this
/// test wants to control directly instead of overriding globally.
Widget _buildMacTestWidget({MockAuthStorage? storage}) {
  final mockStorage = storage ?? MockAuthStorage();
  return ProviderScope(
    overrides: [
      authServiceProvider.overrideWithValue(AuthService(storage: mockStorage)),
    ],
    child: MaterialApp(
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            padding: const EdgeInsets.only(top: kMacTitleBarOverlap),
          ),
          child: WindowChromeInsets.scope(
            insets: const WindowChromeInsets(
              height: kMacTitleBarOverlap,
              leading: kMacTrafficLightsWidth,
              trailing: 0,
            ),
            child: const LoginScreen(),
          ),
        ),
      ),
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

  testWidgets(
      'under mac window-chrome insets, the QR overlay close button clears '
      'the traffic lights and still receives the tap', (tester) async {
    await tester.pumpWidget(_buildMacTestWidget());
    await tester.pumpAndSettle();

    await tester.tap(find.textContaining('Scan QR Code'));
    // Lets the async MobileScannerController hookup in `initState` settle;
    // it has no camera to attach to in a widget test and finishes in an
    // error state, but that happens off the tree this test inspects.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    final closeButton = find.widgetWithIcon(IconButton, Icons.close);
    expect(closeButton, findsOneWidget);
    final rect = tester.getRect(closeButton);
    expect(
      rect.top >= kMacTitleBarOverlap || rect.left >= kMacTrafficLightsWidth,
      isTrue,
      reason: 'close button rect $rect overlaps the traffic lights band',
    );

    // With `WindowTitleRow` mounted before the overlay in the Stack, the
    // overlay (and its close button) paints on top of the drag band, so the
    // tap reaches the button instead of starting a window drag.
    await tester.tap(closeButton);
    await tester.pump();
    expect(find.byIcon(Icons.close), findsNothing);
  });
}
