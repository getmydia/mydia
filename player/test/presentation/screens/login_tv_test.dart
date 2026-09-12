// Directional-tier proof that LoginScreen actually wires
// InputCapabilities.directionalPrimary into the real widget tree, not just
// that the underlying predicate returns the right bool in isolation (that
// part is covered, tier-agnostic, by login_test.dart).
//
// A Chromecast with Google TV has no camera: the "Scan QR Code" button must
// be gone, the claim code field must grab focus on arrival so the leanback
// IME opens without the viewer hunting for it, and the segmented control
// that switches between Quick Pair and Direct Server must itself be a D-pad
// focus stop, since a viewer who lands on the wrong tab has no other way to
// reach the other one.
//
// InputCapabilities.directionalPrimary is compile-time influenced
// (MYDIA_FORCE_TV, a bool.fromEnvironment flag), so a plain `flutter test`
// run never sees it as true: every test in this file needs the whole
// process compiled with --dart-define=MYDIA_FORCE_TV=true. Without that,
// this file's tests skip themselves rather than fail, so it stays green
// when a whole-suite run sweeps it up without the define. CI's "Run
// television-tier tests" step enumerates test/**/*_tv_test.dart and runs
// that list with the define.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/auth/auth_service.dart';
import 'package:player/core/player/input_capabilities.dart';
import 'package:player/presentation/screens/login/login_controller.dart';
import 'package:player/presentation/screens/login_screen.dart';
import 'package:player/presentation/widgets/focus_highlight.dart';
import 'package:player/presentation/widgets/pin_code_display.dart';
import 'package:player/presentation/widgets/tv_keypad.dart';

import '../../test_utils/mock_auth_storage.dart';

class _FakeLoginController extends LoginController {
  String? submittedClaimCode;
  String? failureError;

  @override
  LoginState build() => LoginState.initial();

  @override
  Future<void> pairWithClaimCode(String claimCode) async {
    submittedClaimCode = claimCode;
    if (failureError != null) {
      state = state.copyWith(
        error: failureError,
        claimCodeStatus: ClaimCodeStatus.error,
      );
    }
  }
}

Widget _buildTestWidget({LoginController? controller}) => ProviderScope(
      overrides: [
        authServiceProvider
            .overrideWithValue(AuthService(storage: MockAuthStorage())),
        if (controller != null)
          loginControllerProvider.overrideWith(() => controller),
      ],
      child: const MaterialApp(home: LoginScreen()),
    );

Future<void> _pumpLoginScreen(
  WidgetTester tester, {
  LoginController? controller,
}) async {
  tester.view.physicalSize = const Size(1920, 1080);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(_buildTestWidget(controller: controller));
  await tester.pumpAndSettle();
}

Finder _findPinCodeText(String char) => find.descendant(
      of: find.byType(PinCodeDisplay),
      matching: find.text(char),
    );

void main() {
  final skipReason = InputCapabilities.directionalPrimary
      ? false
      : 'requires --dart-define=MYDIA_FORCE_TV=true to force '
          'InputCapabilities.directionalPrimary; forcedTv is a compile-time '
          'flag (bool.fromEnvironment), so this file is a deliberate no-op '
          'unless the whole test process is compiled with that define. CI '
          'runs it explicitly in the "Run television-tier tests" step.';

  group('LoginScreen on the directional tier (requires MYDIA_FORCE_TV=true)',
      () {
    testWidgets('withholds the camera QR scanner', (tester) async {
      await _pumpLoginScreen(tester);

      expect(find.textContaining('Scan QR Code'), findsNothing);
    });

    testWidgets(
        'renders TV two-column layout without mobile text field, showing keypad and pin code display',
        (tester) async {
      await _pumpLoginScreen(tester);

      expect(find.byType(TextField), findsNothing);
      expect(find.byType(TvKeypad), findsOneWidget);
      expect(find.byType(PinCodeDisplay), findsOneWidget);
    });

    testWidgets('autofocuses first keypad key [A] on arrival', (tester) async {
      await _pumpLoginScreen(tester);

      final firstKeyFinder = find.ancestor(
        of: find.byKey(const ValueKey('tv-key-A')),
        matching: find.byType(FocusHighlight),
      );
      expect(firstKeyFinder, findsOneWidget);
      final focusHighlight = tester.widget<FocusHighlight>(firstKeyFinder);
      expect(focusHighlight.autofocus, isTrue);
    });

    testWidgets('typing characters on keypad updates PinCodeDisplay',
        (tester) async {
      await _pumpLoginScreen(tester);

      await tester.tap(find.byKey(const ValueKey('tv-key-A')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('tv-key-B')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('tv-key-3')));
      await tester.pump();

      expect(_findPinCodeText('A'), findsOneWidget);
      expect(_findPinCodeText('B'), findsOneWidget);
      expect(_findPinCodeText('3'), findsOneWidget);
    });

    testWidgets('entering 6 characters triggers pairWithClaimCode',
        (tester) async {
      final fakeController = _FakeLoginController();
      await _pumpLoginScreen(tester, controller: fakeController);

      for (final char in ['A', 'B', 'C', 'D', 'E', 'F']) {
        await tester.tap(find.byKey(ValueKey('tv-key-$char')));
        await tester.pump();
      }

      expect(fakeController.submittedClaimCode, equals('ABCDEF'));
    });

    testWidgets(
        'remote Back key deletes last character when input is non-empty',
        (tester) async {
      await _pumpLoginScreen(tester);

      await tester.tap(find.byKey(const ValueKey('tv-key-A')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('tv-key-B')));
      await tester.pump();

      expect(_findPinCodeText('A'), findsOneWidget);
      expect(_findPinCodeText('B'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      expect(_findPinCodeText('A'), findsOneWidget);
      expect(_findPinCodeText('B'), findsNothing);

      // Also test system pop route (e.g. Android TV OS back)
      await tester.binding.handlePopRoute();
      await tester.pump();

      expect(_findPinCodeText('A'), findsNothing);
    });

    testWidgets('settings button in TV header is wrapped in FocusHighlight',
        (tester) async {
      await _pumpLoginScreen(tester);

      final settingsHighlightFinder = find.ancestor(
        of: find.byTooltip('Relay & Network Settings'),
        matching: find.byType(FocusHighlight),
      );
      expect(settingsHighlightFinder, findsOneWidget);
    });

    testWidgets('error state preserves entered code in PinCodeDisplay',
        (tester) async {
      final fakeController = _FakeLoginController()
        ..failureError = 'Invalid or expired claim code';
      await _pumpLoginScreen(tester, controller: fakeController);

      for (final char in ['A', 'B', 'C', 'D', 'E', 'F']) {
        await tester.tap(find.byKey(ValueKey('tv-key-$char')));
        await tester.pump();
      }

      expect(fakeController.submittedClaimCode, equals('ABCDEF'));
      expect(find.text('Invalid or expired claim code'), findsOneWidget);

      final pinDisplay =
          tester.widget<PinCodeDisplay>(find.byType(PinCodeDisplay));
      expect(pinDisplay.code, equals('ABCDEF'));
      expect(pinDisplay.hasError, isTrue);

      for (final char in ['A', 'B', 'C', 'D', 'E', 'F']) {
        expect(_findPinCodeText(char), findsOneWidget);
      }
    });

    testWidgets(
        'remote Back key dismisses advanced settings overlay when open instead of deleting characters',
        (tester) async {
      await _pumpLoginScreen(tester);

      // Enter a character first to verify it is NOT deleted when Back dismisses the overlay
      await tester.tap(find.byKey(const ValueKey('tv-key-A')));
      await tester.pump();
      expect(_findPinCodeText('A'), findsOneWidget);

      // Open advanced settings overlay via header settings button
      final settingsButton = find.byTooltip('Relay & Network Settings');
      expect(settingsButton, findsOneWidget);
      await tester.tap(settingsButton);
      await tester.pump();

      expect(find.text('Advanced Settings'), findsOneWidget);

      // Remote Back key (Escape) dismisses the overlay and preserves the entered character
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      expect(find.text('Advanced Settings'), findsNothing);
      expect(_findPinCodeText('A'), findsOneWidget);

      // Open again to verify system pop route (Android TV back) also dismisses overlay
      await tester.tap(settingsButton);
      await tester.pump();

      expect(find.text('Advanced Settings'), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pump();

      expect(find.text('Advanced Settings'), findsNothing);
      expect(_findPinCodeText('A'), findsOneWidget);

      // Once overlay is dismissed, remote Back key deletes the character as normal
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      expect(_findPinCodeText('A'), findsNothing);
    });

    group('segment tab focus', () {
      setUp(() {
        FocusManager.instance.highlightStrategy =
            FocusHighlightStrategy.alwaysTraditional;
      });

      tearDown(() {
        FocusManager.instance.highlightStrategy =
            FocusHighlightStrategy.automatic;
      });

      testWidgets('Direct Server tab is a D-pad focus stop with a ring',
          (tester) async {
        await _pumpLoginScreen(tester);

        final ringFinder = find.descendant(
          of: find.ancestor(
            of: find.text('Direct Server'),
            matching: find.byType(FocusHighlight),
          ),
          matching: find.byKey(FocusHighlight.ringKey),
        );
        expect(ringFinder, findsOneWidget);

        bool ringShowing() {
          final decorated = tester.widget<DecoratedBox>(ringFinder);
          return (decorated.decoration as BoxDecoration).border != null;
        }

        // Stepping focus traversal through to Direct Server tab
        final scope = FocusScope.of(tester.element(find.text('Direct Server')));
        var steps = 0;
        while (!ringShowing() && steps < 50) {
          scope.nextFocus();
          await tester.pump();
          steps++;
        }

        expect(
          ringShowing(),
          isTrue,
          reason: 'Direct Server tab was never reached by focus traversal',
        );
      });
    });
  }, skip: skipReason);
}
