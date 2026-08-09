import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/update/update_provider.dart';
import 'package:player/domain/models/app_update.dart';
import 'package:player/presentation/screens/settings/widgets/update_card.dart';

class _FakeUpdateNotifier extends UpdateNotifier {
  _FakeUpdateNotifier(this._state);

  final UpdateState _state;

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
  bool? supportedOverride,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        updateProvider.overrideWith(() => _FakeUpdateNotifier(state)),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [UpdateCard(supportedOverride: supportedOverride)],
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
      supportedOverride: true,
    );

    expect(find.text('Update Now'), findsNothing);
  });

  testWidgets('renders nothing on a platform that cannot self-update',
      (tester) async {
    await _pump(
      tester,
      state: UpdateState(
        currentVersion: '0.14.2',
        availableUpdate: _update(),
      ),
      supportedOverride: false,
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
      supportedOverride: true,
    );

    expect(find.text('Update Now'), findsOneWidget);
    expect(find.text('Release Notes'), findsOneWidget);
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
      supportedOverride: true,
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
      supportedOverride: true,
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
}
