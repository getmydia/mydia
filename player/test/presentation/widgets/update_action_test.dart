import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/update/install_environment.dart';
import 'package:player/core/update/update_provider.dart';
import 'package:player/domain/models/available_update.dart';
import 'package:player/presentation/widgets/update_action.dart';

class _FakeUpdateNotifier extends UpdateNotifier {
  _FakeUpdateNotifier(this._state);

  final UpdateState _state;
  int requestCount = 0;

  @override
  UpdateState build() => _state;

  @override
  Future<void> requestUpdate({
    void Function(double progress)? onProgress,
  }) async =>
      requestCount++;
}

AppUpdate _update() => AppUpdate(
      version: '0.15.0',
      downloadUrl: 'https://example.invalid/player-linux-v0.15.0.tar.gz',
      releaseNotesUrl: 'https://example.invalid/releases/0.15.0',
      releaseTitle: 'Faster library scans',
      publishedAt: DateTime.utc(2026, 8, 1),
    );

const _flatpakUpdate =
    FlatpakRemoteUpdate(releaseNotesUrl: 'https://example.invalid/releases');

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
    expect(notifier.requestCount, 0);
    expect(launched, isEmpty);
  });

  testWidgets('confirming an in-place update requests it', (tester) async {
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

    expect(notifier.requestCount, 1);
  });

  testWidgets('cancelling an in-place update requests nothing', (tester) async {
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

    expect(notifier.requestCount, 0);
  });

  testWidgets(
      'a Flatpak install requests the update through the backend directly, '
      'with no dialog and no terminal command', (tester) async {
    final notifier = _FakeUpdateNotifier(
      UpdateState(currentVersion: '0.14.2', availableUpdate: _flatpakUpdate),
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

    // The portal already knows how to fetch and apply its own update, so
    // this used to tell the user to run `flatpak update` themselves; now it
    // just asks the backend to do it.
    expect(notifier.requestCount, 1);
    expect(find.byType(AlertDialog), findsNothing);
    expect(launched, isEmpty);
  });

  testWidgets('a read-only install opens the release page and requests nothing',
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
    expect(notifier.requestCount, 0);
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
    expect(notifier.requestCount, 0);
    expect(launched, isEmpty);
  });
}
