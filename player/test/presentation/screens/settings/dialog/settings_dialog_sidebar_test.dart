import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/p2p/p2p_service.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/core/theme/palette.dart';
import 'package:player/core/update/update_provider.dart';
import 'package:player/domain/models/available_update.dart';
import 'package:player/domain/models/user_settings.dart';
import 'package:player/presentation/widgets/connection_status_dot.dart';
import 'package:player/l10n/l10n.dart';
import 'package:player/presentation/screens/settings/dialog/settings_dialog.dart';
import 'package:player/presentation/screens/settings/dialog/settings_dialog_sidebar.dart';
import 'package:player/presentation/screens/settings/dialog/settings_sidebar_status.dart';
import 'package:player/presentation/screens/settings/settings_controller.dart';

const _account = SettingsSidebarAccount(
  username: 'admin',
  serverUrl: 'https://media.example.test',
);

Widget _app(Widget child) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(
    body: Align(alignment: Alignment.topLeft, child: child),
  ),
);

Future<List<SettingsCategory>> _pump(
  WidgetTester tester, {
  SettingsCategory selected = SettingsCategory.playback,
  bool compact = false,
  SettingsSidebarAccount? account = _account,
  Widget? connectionStatus,
  bool updateAvailable = false,
}) async {
  tester.view.physicalSize = const Size(1200, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final selections = <SettingsCategory>[];
  // No ProviderScope: the sidebar takes plain values.
  await tester.pumpWidget(
    _app(
      SizedBox(
        height: 700,
        child: SettingsDialogSidebar(
          selected: selected,
          compact: compact,
          onSelect: selections.add,
          account: account,
          connectionStatus: connectionStatus,
          updateAvailable: updateAvailable,
        ),
      ),
    ),
  );
  await tester.pump();
  return selections;
}

Finder _item(SettingsCategory c) =>
    find.byKey(Key('settings-category-${c.name}'));

class _FakeP2pStatusNotifier extends P2pStatusNotifier {
  @override
  P2pStatus build() => const P2pStatus(
    isInitialized: true,
    isRelayConnected: false,
    connectedPeersCount: 0,
  );
}

class _FakeUpdateNotifier extends UpdateNotifier {
  _FakeUpdateNotifier([this.update]);

  final AvailableUpdate? update;

  @override
  UpdateState build() => UpdateState(availableUpdate: update);
}

class _FakeSettingsController extends SettingsController {
  @override
  Future<UserSettings> build() async => const UserSettings(
    serverUrl: 'https://media.example.test',
    username: 'admin',
    defaultQuality: '1080p',
  );
}

Future<void> _pumpStatus(
  WidgetTester tester, {
  required int accounts,
  String? location,
  AvailableUpdate? update,
}) async {
  tester.view.physicalSize = const Size(1200, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        settingsControllerProvider.overrideWith(_FakeSettingsController.new),
        mydiaAccountCountProvider.overrideWithValue(accounts),
        // The dot reads the active source; none keeps Hive out of this.
        activeSourceIdProvider.overrideWithValue(null),
        updateProvider.overrideWith(() => _FakeUpdateNotifier(update)),
        p2pStatusNotifierProvider.overrideWith(_FakeP2pStatusNotifier.new),
      ],
      child: _app(
        SizedBox(
          height: 700,
          child: SettingsSidebarStatus(
            selected: SettingsCategory.playback,
            compact: false,
            onSelect: (_) {},
            location: location,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('categories in two groups', (tester) async {
    await _pump(tester);
    final appearance = tester.getRect(_item(SettingsCategory.appearance));
    final diagnostics = tester.getRect(_item(SettingsCategory.diagnostics));
    final dividers = find.byType(Divider);
    final between = tester
        .widgetList<Divider>(dividers)
        .map((d) => tester.getRect(find.byWidget(d)).center.dy)
        .where((dy) => dy > appearance.bottom && dy < diagnostics.top);
    expect(between, hasLength(1));

    // Nothing else separates the first group.
    final connections = tester.getRect(_item(SettingsCategory.connections));
    final inFirstGroup = tester
        .widgetList<Divider>(dividers)
        .map((d) => tester.getRect(find.byWidget(d)).center.dy)
        .where((dy) => dy > connections.top && dy < appearance.top);
    expect(inFirstGroup, isEmpty);
  });

  testWidgets('selected item is tinted', (tester) async {
    await _pump(tester, selected: SettingsCategory.backup);
    final palette = tester.element(_item(SettingsCategory.backup)).palette;
    expect(
      tester.widget<Material>(_item(SettingsCategory.backup)).color,
      palette.primary.withValues(alpha: 0.16),
    );
    expect(
      tester.widget<Material>(_item(SettingsCategory.playback)).color,
      Colors.transparent,
    );
    expect(tester.getSize(_item(SettingsCategory.backup)).height, 34);
  });

  testWidgets('account card shows name and host; tapping opens connections', (
    tester,
  ) async {
    final selections = await _pump(tester);
    final card = find.byKey(const Key('settings-sidebar-account'));
    expect(card, findsOneWidget);
    expect(
      find.descendant(of: card, matching: find.text('admin')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: card, matching: find.text('media.example.test')),
      findsOneWidget,
    );

    await tester.tap(card);
    expect(selections, [SettingsCategory.connections]);
  });

  testWidgets('account card exposes button semantics', (tester) async {
    await _pump(tester);
    final card = find.byKey(const Key('settings-sidebar-account'));
    expect(
      find.ancestor(
        of: card,
        matching: find.byWidgetPredicate(
          (w) => w is Semantics && w.properties.button == true,
        ),
      ),
      findsOneWidget,
    );
  });

  testWidgets('account card avatar keeps a whole emoji grapheme', (
    tester,
  ) async {
    await _pump(
      tester,
      account: const SettingsSidebarAccount(
        username: '\u{1F600}smile',
        serverUrl: 'https://media.example.test',
      ),
    );
    final card = find.byKey(const Key('settings-sidebar-account'));
    expect(
      find.descendant(of: card, matching: find.text('\u{1F600}')),
      findsOneWidget,
    );
  });

  testWidgets('no account, no card', (tester) async {
    await _pump(tester, account: null);
    expect(find.byKey(const Key('settings-sidebar-account')), findsNothing);
  });

  testWidgets('update pill only when available', (tester) async {
    await _pump(tester, updateAvailable: true);
    final pill = find.byKey(const Key('settings-sidebar-update-badge'));
    expect(pill, findsOneWidget);
    expect(
      find.descendant(of: _item(SettingsCategory.about), matching: pill),
      findsOneWidget,
    );
    expect(find.text('Update'), findsOneWidget);

    await _pump(tester);
    expect(
      find.byKey(const Key('settings-sidebar-update-badge')),
      findsNothing,
    );
  });

  testWidgets('connection status renders after servers', (tester) async {
    await _pump(tester, connectionStatus: const SizedBox(key: Key('status')));
    expect(
      find.descendant(
        of: _item(SettingsCategory.connections),
        matching: find.byKey(const Key('status')),
      ),
      findsOneWidget,
    );
  });

  testWidgets('tapping an item selects it', (tester) async {
    final selections = await _pump(tester);
    await tester.tap(_item(SettingsCategory.diagnostics));
    expect(selections, [SettingsCategory.diagnostics]);
  });

  testWidgets('compact keeps the icon rail', (tester) async {
    await _pump(
      tester,
      compact: true,
      updateAvailable: true,
      connectionStatus: const SizedBox(key: Key('status')),
    );
    expect(tester.getSize(find.byType(SettingsDialogSidebar)).width, 64);
    expect(find.byKey(const Key('settings-sidebar-account')), findsNothing);
    expect(
      find.byKey(const Key('settings-sidebar-update-badge')),
      findsNothing,
    );
    final l10n = tester.element(_item(SettingsCategory.about)).l10n;
    for (final c in SettingsCategory.values) {
      expect(
        find.descendant(
          of: _item(c),
          matching: find.byWidgetPredicate(
            (w) => w is Tooltip && w.message == c.label(l10n),
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(Key('settings-category-label-${c.name}')),
        findsNothing,
      );
    }
  });

  testWidgets('full width is 236 with labels', (tester) async {
    await _pump(tester);
    expect(tester.getSize(find.byType(SettingsDialogSidebar)).width, 236);
    for (final c in SettingsCategory.values) {
      expect(
        find.byKey(Key('settings-category-label-${c.name}')),
        findsOneWidget,
      );
    }
  });

  testWidgets('SettingsSidebarStatus shows the account with one account', (
    tester,
  ) async {
    await _pumpStatus(tester, accounts: 1);
    expect(find.byKey(const Key('settings-sidebar-account')), findsOneWidget);
    expect(
      find.byKey(const Key('settings-sidebar-update-badge')),
      findsNothing,
    );
  });

  testWidgets('SettingsSidebarStatus hides the account with several accounts', (
    tester,
  ) async {
    await _pumpStatus(tester, accounts: 2);
    expect(find.byKey(const Key('settings-sidebar-account')), findsNothing);
  });

  testWidgets('SettingsSidebarStatus draws the dot and the update pill', (
    tester,
  ) async {
    await _pumpStatus(
      tester,
      accounts: 1,
      location: '/',
      update: const FlatpakRemoteUpdate(releaseNotesUrl: 'https://x.test'),
    );
    final dot = find.descendant(
      of: _item(SettingsCategory.connections),
      matching: find.byType(ConnectionStatusDot),
    );
    expect(dot, findsOneWidget);
    expect(tester.getSize(dot), const Size.square(7));
    expect(
      find.byKey(const Key('settings-sidebar-update-badge')),
      findsOneWidget,
    );
  });
}
