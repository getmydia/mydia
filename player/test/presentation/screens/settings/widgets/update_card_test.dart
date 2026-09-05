import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/update/update_backend.dart';
import 'package:player/core/update/update_provider.dart';
import 'package:player/domain/models/available_update.dart';
import 'package:player/presentation/screens/settings/settings_screen.dart';
import 'package:player/presentation/screens/settings/widgets/settings_section.dart';
import 'package:player/presentation/screens/settings/widgets/update_card.dart';

class _FakeUpdateNotifier extends UpdateNotifier {
  _FakeUpdateNotifier(this._state, {this.canUpdateInPlace = false});

  final UpdateState _state;

  @override
  final bool canUpdateInPlace;

  @override
  UpdateState build() => _state;
}

AppUpdate _update() => AppUpdate(
      version: '0.15.0',
      downloadUrl: 'https://example.invalid/mydia-0.15.0.AppImage',
      releaseNotesUrl: 'https://example.invalid/releases/0.15.0',
      releaseTitle: 'Faster library scans',
      publishedAt: DateTime.utc(2026, 8, 1),
    );

Future<void> _pump(
  WidgetTester tester, {
  required UpdateState state,
  bool canUpdateInPlace = false,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        updateProvider.overrideWith(
          () => _FakeUpdateNotifier(state, canUpdateInPlace: canUpdateInPlace),
        ),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: ListView(
            children: const [UpdateCard()],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// Pumps the card in a [Column] rather than a [ListView], for the two tests
/// that measure its height.
///
/// A zero-height child inside a ListView is culled by the sliver, so
/// `find.byType(UpdateCard)` matches nothing at all and `getSize` throws
/// `Bad state: No element` rather than reporting zero. A Column keeps the
/// element in the tree at zero height, which is the thing under test.
///
/// `stretch` so children get the full width, matching what the ListView in
/// [_pump] gives them.
Future<void> _pumpInColumn(
  WidgetTester tester, {
  required UpdateState state,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        updateProvider.overrideWith(() => _FakeUpdateNotifier(state)),
      ],
      child: const MaterialApp(
        home: Scaffold(
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [UpdateCard()],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('renders nothing when no update is available', (tester) async {
    await _pump(
      tester,
      state: const UpdateState(currentVersion: '0.14.2'),
    );

    expect(find.text('Update Now'), findsNothing);
  });

  testWidgets('offers the update when one is available on a supported platform',
      (tester) async {
    await _pump(
      tester,
      state: UpdateState(
        currentVersion: '0.14.2',
        availableUpdate: _update(),
      ),
    );

    expect(find.text('Update Now'), findsOneWidget);
    expect(find.text('Release Notes'), findsOneWidget);
    expect(find.text('Update available: v0.15.0'), findsOneWidget);
    expect(find.text('Faster library scans'), findsOneWidget);
  });

  testWidgets('shows progress instead of buttons while applying',
      (tester) async {
    await _pump(
      tester,
      state: UpdateState(
        currentVersion: '0.14.2',
        availableUpdate: _update(),
        isApplying: true,
        downloadProgress: 0.42,
      ),
    );

    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.text('Downloading 42%'), findsOneWidget);
    expect(find.text('Update Now'), findsNothing);
  });

  testWidgets('at zero progress the label drops the misleading percentage',
      (tester) async {
    // The bar is indeterminate at zero, so a "0%" label would claim a
    // precision the bar itself is not showing.
    await _pump(
      tester,
      state: UpdateState(
        currentVersion: '0.14.2',
        availableUpdate: _update(),
        isApplying: true,
      ),
    );

    expect(find.text('Downloading'), findsOneWidget);
    expect(find.text('Downloading 0%'), findsNothing);
    expect(
      tester
          .widget<LinearProgressIndicator>(
            find.byType(LinearProgressIndicator),
          )
          .value,
      isNull,
    );
  });

  testWidgets('a hidden card contributes no height at all', (tester) async {
    // The screen emits no spacer around this card, so a hidden card that still
    // occupied space would open a gap under the identity band.
    await _pumpInColumn(
      tester,
      state: const UpdateState(currentVersion: '0.14.2'),
    );

    expect(tester.getSize(find.byType(UpdateCard)).height, 0);
  });

  testWidgets(
      'a visible card carries the space that separates it from the '
      'section below', (tester) async {
    await _pumpInColumn(
      tester,
      state: UpdateState(
        currentVersion: '0.14.2',
        availableUpdate: _update(),
      ),
    );

    final outer = tester.getSize(find.byType(UpdateCard)).height;
    final card = tester.getSize(find.byType(SettingsCard)).height;

    expect(outer - card, 18);
  });

  testWidgets(
      'a Flatpak update, which names no version, never renders the '
      'literal word null', (tester) async {
    // FlatpakRemoteUpdate.version is null by construction: the portal knows
    // only that the remote carries a newer commit. Interpolating that
    // straight into 'v${update.version}' would print "vnull" once the
    // Flatpak backend is monitoring, which is the common case.
    await _pump(
      tester,
      state: const UpdateState(
        currentVersion: '0.14.2',
        availableUpdate: FlatpakRemoteUpdate(
          releaseNotesUrl: 'https://example.invalid/releases',
        ),
      ),
    );

    expect(find.textContaining('null'), findsNothing);
    expect(find.text('A new version of Mydia Player is available'),
        findsOneWidget);
  });

  group('Flatpak', () {
    testWidgets('a version-less update offers an update button and no version',
        (tester) async {
      await _pump(
        tester,
        state: const UpdateState(
          availableUpdate: FlatpakRemoteUpdate(
            releaseNotesUrl: 'https://example.invalid/releases',
          ),
          manualCheck: ManualCheckBehaviour.checksAndInstalls,
        ),
      );

      expect(
        find.text('A new version of Mydia Player is available'),
        findsOneWidget,
      );
      expect(find.text('Update Now'), findsOneWidget);
      // Nothing may claim a version the portal never reported.
      expect(find.textContaining(RegExp(r'v\d')), findsNothing);
    });

    testWidgets(
        'the update-now confirm dialog for a version-less update never '
        'renders the literal word null', (tester) async {
      // Task 8 covered the heading only, since its regression test never
      // taps anything. The dialog is built from a separate onPressed closure
      // inside showDialog, so it needs its own coverage: reverting the null
      // guard there would otherwise pass the whole suite undetected.
      await _pump(
        tester,
        state: const UpdateState(
          availableUpdate: FlatpakRemoteUpdate(
            releaseNotesUrl: 'https://example.invalid/releases',
          ),
          manualCheck: ManualCheckBehaviour.checksAndInstalls,
        ),
        canUpdateInPlace: true,
      );

      await tester.tap(find.text('Update Now'));
      await tester.pumpAndSettle();

      expect(find.text('Update Mydia'), findsOneWidget);
      expect(find.textContaining('null'), findsNothing);
    });

    testWidgets('an already-installed update offers only a restart',
        (tester) async {
      await _pump(
        tester,
        state: const UpdateState(
          availableUpdate: FlatpakRemoteUpdate(
            releaseNotesUrl: 'https://example.invalid/releases',
            installedAwaitingRestart: true,
          ),
          manualCheck: ManualCheckBehaviour.checksAndInstalls,
        ),
      );

      expect(find.text('Restart to finish updating'), findsOneWidget);
      expect(find.text('Restart'), findsOneWidget);
      expect(find.text('Update Now'), findsNothing);
    });

    testWidgets('a restart-required state shows the restart action',
        (tester) async {
      await _pump(
        tester,
        state: const UpdateState(
          restartRequired: true,
          manualCheck: ManualCheckBehaviour.checksAndInstalls,
        ),
      );

      expect(find.text('Restart'), findsOneWidget);
    });

    testWidgets('a notice is shown when there was nothing to install',
        (tester) async {
      await _pump(
        tester,
        state: const UpdateState(
          notice: "You're up to date",
          manualCheck: ManualCheckBehaviour.checksAndInstalls,
        ),
      );

      expect(find.text("You're up to date"), findsOneWidget);
    });
  });

  group('updateCheckSubtitle', () {
    test('Sparkle keeps its own string', () {
      expect(
        updateCheckSubtitle(
          behaviour: ManualCheckBehaviour.delegatesToSparkle,
          update: null,
        ),
        'Opens the Sparkle update dialog',
      );
    });

    test('Sparkle wording wins even when a version is known', () {
      // An ordering property, not a formatting one. If a later edit checked
      // the version before the behaviour, macOS would start advertising a
      // version in a row that only ever opens Sparkle's own dialog.
      expect(
        updateCheckSubtitle(
          behaviour: ManualCheckBehaviour.delegatesToSparkle,
          update: _update(),
        ),
        'Opens the Sparkle update dialog',
      );
    });

    test('a known version is named', () {
      expect(
        updateCheckSubtitle(
          behaviour: ManualCheckBehaviour.checksOnly,
          update: _update(),
        ),
        'v0.15.0 available',
      );
    });

    test('a version-less update says an update is available', () {
      expect(
        updateCheckSubtitle(
          behaviour: ManualCheckBehaviour.checksAndInstalls,
          update: const FlatpakRemoteUpdate(
            releaseNotesUrl: 'https://example.invalid/releases',
          ),
        ),
        'An update is available',
      );
    });

    test('a check-and-install row says so when nothing is pending', () {
      expect(
        updateCheckSubtitle(
          behaviour: ManualCheckBehaviour.checksAndInstalls,
          update: null,
        ),
        'Checks and installs the newest build',
      );
    });

    test('nothing pending on a check-only row reports up to date', () {
      expect(
        updateCheckSubtitle(
          behaviour: ManualCheckBehaviour.checksOnly,
          update: null,
        ),
        "You're up to date",
      );
    });
  });
}
