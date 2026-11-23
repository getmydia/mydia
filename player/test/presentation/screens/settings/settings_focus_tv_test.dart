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

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:player/core/backup/backup_providers.dart';
import 'package:player/core/cast/cast_capabilities.dart';
import 'package:player/core/cast/cast_providers.dart';
import 'package:player/core/focus/focus_memory.dart';
import 'package:player/core/p2p/p2p_service.dart';
import 'package:player/core/player/subtitle_size.dart';
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
import 'package:player/presentation/widgets/controls/app_segmented.dart';
import 'package:player/presentation/widgets/focus_highlight.dart';

import '../../../test_utils/mock_auth_storage.dart';
import '../../../test_utils/no_downloads.dart';
import '../../../test_utils/tv_shell_harness.dart';
import '../backup/fake_backup_sync_service.dart';

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
    const SourceId('instance'): const RegistrationFailed('offline', 1, null),
  };
}

var _boxCounter = 0;

/// Whether the primary focus sits inside the widget [finder] matches.
bool _hasFocusIn(Finder finder) {
  final element = finder.evaluate().single;
  var inside = false;
  FocusManager.instance.primaryFocus?.context?.visitAncestorElements((e) {
    inside = identical(e, element);
    return !inside;
  });
  return inside;
}

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
          remoteControlSettingsProvider.overrideWith(
            (ref) async => RemoteControlSettings(box: box),
          ),
          sourceStoreProvider.overrideWith(
            (ref) async => InMemorySourceStore(),
          ),
          sourceSecretsProvider.overrideWithValue(
            SourceSecrets(MockAuthStorage()),
          ),
          // The cast button is the one focus stop outside the list.
          castCapabilitiesProvider.overrideWithValue(
            const CastCapabilities.full(),
          ),
          ...noHiveOverrides,
          backupSyncServiceProvider.overrideWithValue(FakeBackupSyncService()),
        ],
      );
    }

    /// The focus node of every row in the list, top to bottom.
    List<FocusNode> rows(WidgetTester tester) => [
      for (final ring
          in find.byKey(FocusHighlight.ringKey, skipOffstage: false).evaluate())
        Focus.of(ring),
    ];

    void expectOnRow(WidgetTester tester, int index) {
      final row = rows(tester)[index];
      expect(
        row.hasPrimaryFocus,
        isTrue,
        reason:
            'expected row $index, focus is on ${describeFocus()} '
            '${FocusManager.instance.primaryFocus?.rect}',
      );
    }

    const cast = Key('cast-button');

    testWidgets('the list entered for the first time lands on its first row', (
      tester,
    ) async {
      await pumpSettings(tester);
      // Settings opens on its first focus stop in reading order, which with
      // a cast button is that button, above the list.
      expectFocusIn(cast);

      await press(tester, LogicalKeyboardKey.arrowDown);

      expectOnRow(tester, 0);
    });

    testWidgets('card is the first focus target after the update card', (
      tester,
    ) async {
      await pumpSettings(tester);
      // The update card has nothing focusable unless a release is on offer,
      // so the card is the first stop below the cast button.
      await press(tester, LogicalKeyboardKey.arrowDown);

      // The card's ring is the first row, and it wraps the card.
      expectOnRow(tester, 0);
      expect(
        rows(tester)[0].rect.contains(
          tester.getCenter(find.byKey(const Key('connections-card'))),
        ),
        isTrue,
      );

      // Backup & sync sits between the card and the first section.
      await press(tester, LogicalKeyboardKey.arrowDown);
      expectFocusIn(const Key('backup-switch'));

      await press(tester, LogicalKeyboardKey.arrowDown);

      expectFocusIn(const Key('default-quality-row'));
      expect(find.byKey(const Key('paired-devices-row')), findsNothing);
      expect(find.byKey(const Key('manage-sources-row')), findsNothing);
    });

    testWidgets('playback groups have distinct focus orders', (tester) async {
      await pumpSettings(tester);
      final items = find
          .byType(FocusMemoryItem, skipOffstage: false)
          .evaluate()
          .map((e) => e.widget as FocusMemoryItem)
          .toList();
      final indices = [for (final item in items) item.index];
      expect(indices.toSet().length, indices.length, reason: '$indices');

      int indexOf(Key key) => items
          .firstWhere(
            (i) => find
                .descendant(
                  of: find.byWidget(i, skipOffstage: false),
                  matching: find.byKey(key, skipOffstage: false),
                )
                .evaluate()
                .isNotEmpty,
          )
          .index;
      expect(
        indexOf(const Key('language-row')),
        greaterThan(indexOf(const Key('auto-skip-commercials-switch'))),
      );
    });

    /// The option [i] of the grid keyed [grid]; every grid numbers its options
    /// `settings-choice-<i>`, so the grid scopes the lookup.
    Finder choice(Key grid, int i) => find.descendant(
      of: find.byKey(grid),
      matching: find.byKey(Key('settings-choice-$i')),
    );

    void expectOnChoice(WidgetTester tester, Key grid, int i) {
      final element = choice(grid, i).evaluate().single;
      final focus = FocusManager.instance.primaryFocus;
      var inside = false;
      focus?.context?.visitAncestorElements((e) {
        inside = identical(e, element);
        return !inside;
      });
      expect(
        inside,
        isTrue,
        reason: 'expected choice $i of $grid, focus is on ${describeFocus()}',
      );
    }

    const themeGrid = Key('theme-preset-row');

    testWidgets('D-pad walks from Skipping into the theme grid and on', (
      tester,
    ) async {
      await pumpSettings(tester);
      final cards = find
          .descendant(
            of: find.byKey(themeGrid),
            matching: find.byWidgetPredicate(
              (w) => w.key.toString().startsWith("[<'settings-choice-"),
            ),
          )
          .evaluate()
          .length;
      expect(cards, greaterThan(1));

      await focusIn(tester, const Key('auto-skip-commercials-switch'));

      // Down from the last Skipping row enters the grid.
      await press(tester, LogicalKeyboardKey.arrowDown);
      final entry = [
        for (var i = 0; i < cards; i++)
          if (choice(themeGrid, i).evaluate().isNotEmpty &&
              _hasFocusIn(choice(themeGrid, i)))
            i,
      ];
      expect(entry, hasLength(1), reason: 'focus is on ${describeFocus()}');
      final first = entry.single;

      // Right walks the cards in order, and stops at the last.
      for (var i = first + 1; i < cards; i++) {
        await press(tester, LogicalKeyboardKey.arrowRight);
        expectOnChoice(tester, themeGrid, i);
      }

      // The Material grid is not offered on a television (Liquid Glass is
      // not available there), so the next stop down is Language.
      expect(find.byKey(const Key('glass-material-row')), findsNothing);
      await press(tester, LogicalKeyboardKey.arrowDown);
      expectFocusIn(const Key('language-row'));

      // And back up lands in the grid again.
      await press(tester, LogicalKeyboardKey.arrowUp);
      final back = [
        for (var i = 0; i < cards; i++)
          if (_hasFocusIn(choice(themeGrid, i))) i,
      ];
      expect(back, hasLength(1), reason: 'focus is on ${describeFocus()}');
    });

    testWidgets('focus order: quality < skipping < theme grid < language', (
      tester,
    ) async {
      await pumpSettings(tester);
      final items = find
          .byType(FocusMemoryItem, skipOffstage: false)
          .evaluate()
          .map((e) => e.widget as FocusMemoryItem)
          .toList();
      int indexOf(Key key) => items
          .firstWhere(
            (i) => find
                .descendant(
                  of: find.byWidget(i, skipOffstage: false),
                  matching: find.byKey(key, skipOffstage: false),
                )
                .evaluate()
                .isNotEmpty,
          )
          .index;

      final quality = indexOf(const Key('default-quality-row'));
      final skipping = indexOf(const Key('auto-skip-segments-switch'));
      final theme = indexOf(themeGrid);
      final language = indexOf(const Key('language-row'));
      expect(quality, lessThan(skipping));
      expect(skipping, lessThan(theme));
      expect(theme, lessThan(language));
    });

    testWidgets('re-entering the list lands on the first theme card', (
      tester,
    ) async {
      await pumpSettings(tester);
      await focusIn(tester, const Key('auto-skip-commercials-switch'));
      await press(tester, LogicalKeyboardKey.arrowDown);
      // Walk off the entry card, so a restored card would not be card 0.
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(_hasFocusIn(choice(themeGrid, 0)), isFalse);

      await focusIn(tester, cast);
      await press(tester, LogicalKeyboardKey.arrowDown);

      // The whole grid is one FocusMemoryItem, so memory restores the item,
      // not the card inside it, and the traversal enters on its first card.
      expectOnChoice(tester, themeGrid, 0);
    });

    testWidgets('the list is re-entered on the row that left it', (
      tester,
    ) async {
      await pumpSettings(tester);
      await press(tester, LogicalKeyboardKey.arrowDown);
      // One more press than rows: the backup switch is not a ringed row.
      for (var i = 0; i < 5; i++) {
        await press(tester, LogicalKeyboardKey.arrowDown);
      }
      expectOnRow(tester, 4);
      // However focus reaches the cast button from here, coming back down
      // returns to row 4, not the row nearest the button.
      await focusIn(tester, cast);

      await press(tester, LogicalKeyboardKey.arrowDown);

      expectOnRow(tester, 4);
    });

    testWidgets('LEFT from a row reaches the rail, RIGHT returns', (
      tester,
    ) async {
      await pumpSettings(tester);
      await press(tester, LogicalKeyboardKey.arrowDown);
      // One more press than rows: the backup switch is not a ringed row,
      // nor is the subtitle size control, whose Left and Right change the
      // size (next test). Row 3 is the stats overlay row just below it.
      for (var i = 0; i < 4; i++) {
        await press(tester, LogicalKeyboardKey.arrowDown);
      }
      expectOnRow(tester, 3);

      await press(tester, LogicalKeyboardKey.arrowLeft);
      expect(
        shell.sidebarRow.hasPrimaryFocus,
        isTrue,
        reason: 'focus is on ${describeFocus()}',
      );

      await press(tester, LogicalKeyboardKey.arrowRight);
      expectOnRow(tester, 3);
    });

    testWidgets('the subtitle size control is one stop; LEFT at Small reaches '
        'the rail', (tester) async {
      await pumpSettings(tester);
      const control = Key('subtitle-size-control');
      await press(tester, LogicalKeyboardKey.arrowDown);
      // Backup switch, default quality, then the control.
      for (var i = 0; i < 3; i++) {
        await press(tester, LogicalKeyboardKey.arrowDown);
      }
      expectFocusIn(control);

      // Medium to Small: the size changes and focus stays.
      await press(tester, LogicalKeyboardKey.arrowLeft);
      expectFocusIn(control);
      expect(
        tester.widget<AppSegmented<SubtitleSize>>(find.byKey(control)).selected,
        SubtitleSize.small,
      );

      // A fresh Left at the first segment leaves for the rail.
      await press(tester, LogicalKeyboardKey.arrowLeft);
      expect(
        shell.sidebarRow.hasPrimaryFocus,
        isTrue,
        reason: 'focus is on ${describeFocus()}',
      );

      await press(tester, LogicalKeyboardKey.arrowRight);
      expectFocusIn(control);

      // One Down leaves the row for the next one.
      await press(tester, LogicalKeyboardKey.arrowDown);
      expectFocusIn(const Key('stats-overlay-switch'));
    });

    testWidgets(
      'a retry row appearing above the track picker does not take its place',
      (tester) async {
        await pumpSettings(tester, update: _TrackedUpdateNotifier.new);
        const stable = Key('update-track-option-stable');
        await focusIn(tester, stable);
        await focusIn(tester, cast);

        final container = ProviderScope.containerOf(
          tester.element(find.byType(SettingsScreen)),
        );
        (container.read(
          nodeRegistrationsProvider.notifier,
        ) as _IdleRegistrations).fail();
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('remote-control-retry-row')),
          findsOneWidget,
        );

        await press(tester, LogicalKeyboardKey.arrowDown);

        expectFocusIn(stable);
      },
    );
  }, skip: tvSkipReason);
}
