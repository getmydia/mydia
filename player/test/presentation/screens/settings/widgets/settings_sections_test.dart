import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:player/l10n/l10n.dart';
import 'package:player/core/remote/node_registration_providers.dart';
import 'package:player/core/remote/registration_status.dart';
import 'package:player/core/remote/remote_control_settings.dart';
import 'package:player/core/sources/source.dart' show SourceId;
import 'package:player/core/update/update_backend.dart';
import 'package:player/core/update/update_provider.dart';
import 'package:player/domain/models/user_settings.dart';
import 'package:player/presentation/screens/settings/dialog/settings_dialog.dart';
import 'package:player/presentation/screens/settings/dialog/settings_panes.dart';
import 'package:player/presentation/screens/settings/settings_controller.dart';
import 'package:player/presentation/screens/settings/widgets/settings_sections.dart';

/// An in-memory Hive box per test, as in `settings_screen_test.dart`: the
/// `bytes:` backend keeps every read and write a completed future, which the
/// fake-async zone of `testWidgets` needs.
late Box<dynamic> _remoteControlBox;
var _remoteControlBoxCounter = 0;

class _FakeUpdateNotifier extends UpdateNotifier {
  _FakeUpdateNotifier(this._state);

  final UpdateState _state;

  @override
  UpdateState build() => _state;
}

/// Serves a fixed settings value without touching secure storage.
class _FakeSettingsController extends SettingsController {
  @override
  Future<UserSettings> build() async => const UserSettings(
    serverUrl: 'mydia.local:4000',
    username: 'admin',
    defaultQuality: '1080p',
  );
}

/// Publishes a fixed registration status without a p2p host or a server.
class _StubRegistration extends NodeRegistrations {
  _StubRegistration(this._status);

  final RegistrationStatus _status;

  @override
  Map<SourceId, RegistrationStatus> build() => {
    const SourceId('acct:owner:inst'): _status,
  };

  @override
  void retryAll() {}
}

Future<void> _pumpSection(
  WidgetTester tester,
  Widget child, {
  String version = '',
  RegistrationStatus registration = const RegistrationIdle(),
}) async {
  await tester.binding.setSurfaceSize(const Size(1000, 1400));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        settingsControllerProvider.overrideWith(_FakeSettingsController.new),
        updateProvider.overrideWith(
          () => _FakeUpdateNotifier(
            UpdateState(
              currentVersion: version,
              manualCheck: ManualCheckBehaviour.checksOnly,
            ),
          ),
        ),
        remoteControlSettingsProvider.overrideWith(
          (ref) async => RemoteControlSettings(box: _remoteControlBox),
        ),
        nodeRegistrationsProvider.overrideWith(
          () => _StubRegistration(registration),
        ),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: SingleChildScrollView(child: child)),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

class _VideoHost extends ConsumerWidget {
  const _VideoHost();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(settingsControllerProvider);
    return PlaybackVideoSection(settings: async.value, failed: async.hasError);
  }
}

/// The desktop dialog opened on its Playback page.
Widget _playbackDialog() => SizedBox(
  height: 1100,
  child: SettingsDialog(
    controller: SettingsDialogController(SettingsCategory.playback),
    // Other categories mount too; only Playback needs its real page here.
    rootPage: (category) => category == SettingsCategory.playback
        ? settingsRootPage(category)
        : const SizedBox.shrink(),
  ),
);

void main() {
  setUp(() async {
    _remoteControlBoxCounter += 1;
    _remoteControlBox = await Hive.openBox<dynamic>(
      'sections_remote_control_$_remoteControlBoxCounter',
      bytes: Uint8List(0),
    );
  });

  tearDown(() async {
    await _remoteControlBox.close();
  });

  testWidgets('playback groups render under their headers', (tester) async {
    await _pumpSection(tester, _playbackDialog());
    expect(find.text('Video'), findsOneWidget);
    expect(find.text('Skipping'), findsOneWidget);
    // The dialog is 600 tall, so the last section sits below the fold of the
    // pane's lazy list until it is scrolled to.
    await tester.scrollUntilVisible(
      find.text('Remote control'),
      200,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('Remote control'), findsOneWidget);
    expect(find.byKey(const Key('default-quality-row')), findsOneWidget);
    expect(
      find.byKey(const Key('remote-control-enabled-switch')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('theme-preset-row')), findsNothing);
    expect(find.byKey(const Key('language-row')), findsNothing);
  });

  testWidgets('skipping footer replaces row subtitles', (tester) async {
    await _pumpSection(tester, _playbackDialog());
    expect(find.text('Off shows a skip button instead'), findsNothing);
    expect(
      find.text('When off, a skip button appears instead.'),
      findsOneWidget,
    );
  });

  testWidgets('the default quality row is a select showing the rung', (
    tester,
  ) async {
    await _pumpSection(tester, const _VideoHost());
    final value = find.descendant(
      of: find.byKey(const Key('default-quality-row')),
      matching: find.byKey(const Key('settings-row-select-value')),
    );
    expect(value, findsOneWidget);
    expect(
      find.descendant(of: value, matching: find.text('1080p')),
      findsOneWidget,
    );
  });

  testWidgets('Remote control shows the registration retry after a failure', (
    tester,
  ) async {
    await _pumpSection(
      tester,
      const RemoteControlSection(),
      registration: const RegistrationFailed('offline', 2, null),
    );
    expect(find.byKey(const Key('remote-control-retry-row')), findsOneWidget);
  });

  testWidgets('About names the app and offers the update check', (
    tester,
  ) async {
    await _pumpSection(tester, const AboutSettingsSection(), version: '1.2.3');
    expect(find.byKey(const Key('about-app-name')), findsOneWidget);
    expect(find.textContaining('1.2.3'), findsOneWidget);
    expect(find.byKey(const Key('check-for-updates-row')), findsOneWidget);
  });
}
