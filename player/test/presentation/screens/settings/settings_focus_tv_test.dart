// Settings remembers its place on a television: the list opens on its first
// row, a move back into it from outside (the title bar's cast button) lands
// on the row that last had focus rather than whichever row sits nearest the
// button, and LEFT to the rail and RIGHT back returns to the same row.
//
// The real SettingsScreen inside the shell's real content region (see
// `tv_shell_harness.dart`), at 1920x1080. Its sections build every row (a
// `Column`, not a lazy list), and the rows sit in a 660px column centred in
// the content area, far from the cast button at the bar's right end.
//
// Requires --dart-define=MYDIA_FORCE_TV=true.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:player/core/cast/cast_capabilities.dart';
import 'package:player/core/cast/cast_providers.dart';
import 'package:player/core/p2p/p2p_service.dart';
import 'package:player/core/remote/node_registration_providers.dart';
import 'package:player/core/remote/registration_status.dart';
import 'package:player/core/remote/remote_control_settings.dart';
import 'package:player/core/sources/source.dart' show SourceId;
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/core/sources/store/source_secrets.dart';
import 'package:player/core/sources/store/source_store.dart';
import 'package:player/core/update/update_backend.dart';
import 'package:player/core/update/update_provider.dart';
import 'package:player/core/update/update_track.dart';
import 'package:player/domain/models/user_settings.dart';
import 'package:player/presentation/screens/settings/settings_controller.dart';
import 'package:player/presentation/screens/settings/settings_screen.dart';
import 'package:player/presentation/widgets/focus_highlight.dart';

import '../../../test_utils/mock_auth_storage.dart';
import '../../../test_utils/no_downloads.dart';
import '../../../test_utils/tv_shell_harness.dart';

class _FakeSettingsController extends SettingsController {
  @override
  Future<UserSettings> build() async => const UserSettings(
        serverUrl: 'mydia.local:4000',
        username: 'admin',
        defaultQuality: '1080p',
      );
}

class _FakeP2pStatusNotifier extends P2pStatusNotifier {
  @override
  P2pStatus build() => const P2pStatus(
        isInitialized: true,
        isRelayConnected: false,
        connectedPeersCount: 0,
      );
}

class _FakeUpdateNotifier extends UpdateNotifier {
  @override
  UpdateState build() => const UpdateState(
        currentVersion: '0.1.0',
        manualCheck: ManualCheckBehaviour.checksOnly,
      );
}

/// An installation that offers a release track picker, as a sideloaded
/// Android TV build does.
class _TrackedUpdateNotifier extends UpdateNotifier {
  @override
  UpdateState build() => const UpdateState(
        currentVersion: '0.1.0',
        manualCheck: ManualCheckBehaviour.checksOnly,
        availableTracks: {UpdateTrack.stable, UpdateTrack.beta},
      );
}

class _IdleRegistrations extends NodeRegistrations {
  @override
  Map<SourceId, RegistrationStatus> build() => const {};

  @override
  void retryAll() {}

  /// A registration failing while Settings is open, which inserts the retry
  /// row under the remote-control switch.
  void fail() => state = {
        const SourceId('instance'):
            const RegistrationFailed('offline', 1, null),
      };
}

var _boxCounter = 0;

void main() {
  group('Settings focus memory (requires MYDIA_FORCE_TV=true)', () {
    late TvShell shell;

    Future<void> pumpSettings(
      WidgetTester tester, {
      UpdateNotifier Function() update = _FakeUpdateNotifier.new,
    }) async {
      // An in-memory box, as settings_screen_test.dart explains: a
      // disk-backed one leaves writes the fake-async zone never drives.
      final box = await Hive.openBox<dynamic>(
        'settings_focus_${_boxCounter++}',
        bytes: Uint8List(0),
      );
      addTearDown(box.close);
      shell = TvShell();
      await shell.pump(
        tester,
        const SettingsScreen(),
        overrides: [
          settingsControllerProvider.overrideWith(_FakeSettingsController.new),
          p2pStatusNotifierProvider.overrideWith(_FakeP2pStatusNotifier.new),
          updateProvider.overrideWith(update),
          nodeRegistrationsProvider.overrideWith(_IdleRegistrations.new),
          remoteControlSettingsProvider
              .overrideWith((ref) async => RemoteControlSettings(box: box)),
          sourceStoreProvider
              .overrideWith((ref) async => InMemorySourceStore()),
          sourceSecretsProvider
              .overrideWithValue(SourceSecrets(MockAuthStorage())),
          // The cast button is the one focus stop outside the list.
          castCapabilitiesProvider
              .overrideWithValue(const CastCapabilities.full()),
          ...noHiveOverrides,
        ],
      );
    }

    /// The focus node of every row in the list, top to bottom.
    List<FocusNode> rows(WidgetTester tester) => [
          for (final ring in find
              .byKey(FocusHighlight.ringKey, skipOffstage: false)
              .evaluate())
            Focus.of(ring),
        ];

    void expectOnRow(WidgetTester tester, int index) {
      final row = rows(tester)[index];
      expect(row.hasPrimaryFocus, isTrue,
          reason: 'expected row $index, focus is on ${describeFocus()} '
              '${FocusManager.instance.primaryFocus?.rect}');
    }

    const cast = Key('cast-button');

    testWidgets('the list entered for the first time lands on its first row',
        (tester) async {
      await pumpSettings(tester);
      // Settings opens on its first focus stop in reading order, which with
      // a cast button is that button, above the list.
      expectFocusIn(cast);

      await press(tester, LogicalKeyboardKey.arrowDown);

      expectOnRow(tester, 0);
    });

    testWidgets('the list is re-entered on the row that left it',
        (tester) async {
      await pumpSettings(tester);
      await press(tester, LogicalKeyboardKey.arrowDown);
      for (var i = 0; i < 6; i++) {
        await press(tester, LogicalKeyboardKey.arrowDown);
      }
      expectOnRow(tester, 6);
      // However focus reaches the cast button from here, coming back down
      // returns to row 6, not the row nearest the button.
      await focusIn(tester, cast);

      await press(tester, LogicalKeyboardKey.arrowDown);

      expectOnRow(tester, 6);
    });

    testWidgets('LEFT from a row reaches the rail, RIGHT returns',
        (tester) async {
      await pumpSettings(tester);
      await press(tester, LogicalKeyboardKey.arrowDown);
      for (var i = 0; i < 4; i++) {
        await press(tester, LogicalKeyboardKey.arrowDown);
      }
      expectOnRow(tester, 4);

      await press(tester, LogicalKeyboardKey.arrowLeft);
      expect(shell.sidebarRow.hasPrimaryFocus, isTrue,
          reason: 'focus is on ${describeFocus()}');

      await press(tester, LogicalKeyboardKey.arrowRight);
      expectOnRow(tester, 4);
    });

    testWidgets(
        'a retry row appearing above the track picker does not take its place',
        (tester) async {
      await pumpSettings(tester, update: _TrackedUpdateNotifier.new);
      const stable = Key('update-track-option-stable');
      await focusIn(tester, stable);
      await focusIn(tester, cast);

      final container = ProviderScope.containerOf(
          tester.element(find.byType(SettingsScreen)));
      (container.read(nodeRegistrationsProvider.notifier) as _IdleRegistrations)
          .fail();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('remote-control-retry-row')), findsOneWidget);

      await press(tester, LogicalKeyboardKey.arrowDown);

      expectFocusIn(stable);
    });
  }, skip: tvSkipReason);
}
