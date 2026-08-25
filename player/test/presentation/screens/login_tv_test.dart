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
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/auth/auth_service.dart';
import 'package:player/core/player/input_capabilities.dart';
import 'package:player/presentation/screens/login_screen.dart';
import 'package:player/presentation/widgets/focus_highlight.dart';

import '../../test_utils/mock_auth_storage.dart';

Widget _buildTestWidget() => ProviderScope(
      overrides: [
        authServiceProvider
            .overrideWithValue(AuthService(storage: MockAuthStorage())),
      ],
      child: const MaterialApp(home: LoginScreen()),
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
      await tester.pumpWidget(_buildTestWidget());
      await tester.pumpAndSettle();

      expect(find.textContaining('Scan QR Code'), findsNothing);
    });

    testWidgets('autofocuses the claim code field on arrival', (tester) async {
      await tester.pumpWidget(_buildTestWidget());
      await tester.pumpAndSettle();

      // Quick Pair is the default tab and the Advanced Settings overlay
      // (which owns its own TextFormField) is not built until opened, so
      // this is the claim code field and nothing else.
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.autofocus, isTrue);
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
        await tester.pumpWidget(_buildTestWidget());
        await tester.pumpAndSettle();

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

        // The claim code field autofocuses first, so traversal does not
        // necessarily start at the tab; step through it rather than assume
        // a position.
        final scope = FocusScope.of(tester.element(find.text('Direct Server')));
        var steps = 0;
        while (!ringShowing() && steps < 10) {
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
