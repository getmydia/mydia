import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/update/install_environment.dart';
import 'package:player/core/update/update_provider.dart';
import 'package:player/domain/models/app_update.dart';
import 'package:player/presentation/widgets/update_action.dart';

class _FakeUpdateNotifier extends UpdateNotifier {
  _FakeUpdateNotifier(this._state);

  final UpdateState _state;
  int applyCount = 0;

  @override
  UpdateState build() => _state;

  // UpdateNotifier.applyUpdate reaches for `_platformUpdater`, a `late final`
  // that only `build()` assigns. Overriding `build` without overriding this
  // too throws LateInitializationError the moment the dialog is confirmed.
  @override
  Future<void> applyUpdate() async => applyCount++;
}

AppUpdate _update() => AppUpdate(
      version: '0.15.0',
      downloadUrl: 'https://example.invalid/player-linux-v0.15.0.tar.gz',
      releaseNotesUrl: 'https://example.invalid/releases/0.15.0',
      releaseTitle: 'Faster library scans',
      publishedAt: DateTime.utc(2026, 8, 1),
    );

Future<void> _pump(
  WidgetTester tester, {
  required _FakeUpdateNotifier notifier,
  required InstallEnvironment environment,
  required List<Uri> launched,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [updateProvider.overrideWith(() => notifier)],
      child: MaterialApp(
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => TextButton(
              onPressed: () => startUpdate(
                context,
                ref,
                environmentOverride: environment,
                launcher: (uri) async => launched.add(uri),
              ),
              child: const Text('go'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('an in-place install asks before closing the app',
      (tester) async {
    final notifier = _FakeUpdateNotifier(
      UpdateState(currentVersion: '0.14.2', availableUpdate: _update()),
    );
    final launched = <Uri>[];

    await _pump(
      tester,
      notifier: notifier,
      environment: InstallEnvironment.inPlace,
      launched: launched,
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Mydia will close and update'), findsOneWidget);
    expect(find.textContaining('0.15.0'), findsOneWidget);
    expect(notifier.applyCount, 0);
    expect(launched, isEmpty);
  });

  testWidgets('confirming an in-place update applies it', (tester) async {
    final notifier = _FakeUpdateNotifier(
      UpdateState(currentVersion: '0.14.2', availableUpdate: _update()),
    );

    await _pump(
      tester,
      notifier: notifier,
      environment: InstallEnvironment.inPlace,
      launched: <Uri>[],
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Update'));
    await tester.pumpAndSettle();

    expect(notifier.applyCount, 1);
  });

  testWidgets('cancelling an in-place update applies nothing', (tester) async {
    final notifier = _FakeUpdateNotifier(
      UpdateState(currentVersion: '0.14.2', availableUpdate: _update()),
    );

    await _pump(
      tester,
      notifier: notifier,
      environment: InstallEnvironment.inPlace,
      launched: <Uri>[],
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect(notifier.applyCount, 0);
  });

  testWidgets('a Flatpak install names the command and downloads nothing',
      (tester) async {
    final notifier = _FakeUpdateNotifier(
      UpdateState(currentVersion: '0.14.2', availableUpdate: _update()),
    );
    final launched = <Uri>[];

    await _pump(
      tester,
      notifier: notifier,
      environment: InstallEnvironment.flatpak,
      launched: launched,
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();

    expect(find.text('flatpak update dev.mydia.player'), findsOneWidget);
    expect(find.text('Copy command'), findsOneWidget);
    // The whole point of the branch: no download, no browser tab.
    expect(notifier.applyCount, 0);
    expect(launched, isEmpty);
  });

  testWidgets(
      'a read-only install opens the release page and downloads nothing',
      (tester) async {
    final notifier = _FakeUpdateNotifier(
      UpdateState(currentVersion: '0.14.2', availableUpdate: _update()),
    );
    final launched = <Uri>[];

    await _pump(
      tester,
      notifier: notifier,
      environment: InstallEnvironment.readOnly,
      launched: launched,
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();

    expect(launched, [Uri.parse('https://example.invalid/releases/0.15.0')]);
    expect(notifier.applyCount, 0);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('with no update available nothing happens at all',
      (tester) async {
    final notifier = _FakeUpdateNotifier(
      const UpdateState(currentVersion: '0.14.2'),
    );
    final launched = <Uri>[];

    await _pump(
      tester,
      notifier: notifier,
      environment: InstallEnvironment.inPlace,
      launched: launched,
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(notifier.applyCount, 0);
    expect(launched, isEmpty);
  });
}
