/// What each settings category shows inside the desktop dialog, and how its
/// rows navigate there.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/sources/source.dart';
import '../../../../core/sources/sources_providers.dart';
import '../../../../l10n/l10n.dart';
import '../../detail/detail_links.dart';
import '../../connections/account_detail_page.dart';
import '../../connections/connections_hub.dart';
import '../../sources/mydia_instance_screen.dart';
import '../diagnostics_screen.dart';
import '../settings_controller.dart';
import '../settings_nav.dart';
import '../widgets/settings_sections.dart';
import 'settings_dialog.dart';

const _bodyPadding = EdgeInsets.fromLTRB(24, 8, 24, 24);

Widget settingsRootPage(SettingsCategory category) => switch (category) {
      SettingsCategory.connections => const _ConnectionsPage(),
      SettingsCategory.playback => const _PlaybackPage(),
      SettingsCategory.diagnostics => const _CategoryPane(
          category: SettingsCategory.diagnostics,
          child: DiagnosticsBody(padding: _bodyPadding),
        ),
      SettingsCategory.about => _CategoryPane(
          category: SettingsCategory.about,
          child: ListView(
            padding: _bodyPadding,
            children: const [AboutSettingsSection()],
          ),
        ),
    };

/// A category's root page, titled with the category's sidebar label.
class _CategoryPane extends StatelessWidget {
  const _CategoryPane({required this.category, required this.child});

  final SettingsCategory category;
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      SettingsPane(title: category.label(context.l10n), child: child);
}

class _PlaybackPage extends ConsumerWidget {
  const _PlaybackPage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsControllerProvider);
    return _CategoryPane(
      category: SettingsCategory.playback,
      child: ListView(
        padding: _bodyPadding,
        children: [
          PlaybackSettingsSection(
            settings: settings.value,
            failed: settings.hasError,
            includeRemoteControl: true,
          ),
          const SizedBox(height: 18),
          const AppearanceSettingsSection(),
        ],
      ),
    );
  }
}

/// The hub under its wide constellation, which already names the page, so
/// the pane header holds only the close button.
class _ConnectionsPage extends StatefulWidget {
  const _ConnectionsPage();

  @override
  State<_ConnectionsPage> createState() => _ConnectionsPageState();
}

class _ConnectionsPageState extends State<_ConnectionsPage> {
  ValueNotifier<String?>? _requests;

  /// The section handed to the hub for one frame. Dropping it afterwards
  /// lets the next request for the same section reach the hub as a change.
  String? _section;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final requests = SettingsDialogScope.of(context).connectionsSection;
    if (identical(requests, _requests)) return;
    _requests?.removeListener(_take);
    _requests = requests..addListener(_take);
    // A dialog opened on a section (`/settings/paired-devices`) asked
    // before this pane mounted.
    final pending = requests.value;
    if (pending != null) {
      requests.value = null;
      _show(pending);
    }
  }

  @override
  void dispose() {
    _requests?.removeListener(_take);
    super.dispose();
  }

  void _take() {
    final requests = _requests;
    final section = requests?.value;
    if (requests == null || section == null) return;
    requests.value = null;
    setState(() => _show(section));
  }

  void _show(String section) {
    _section = section;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _section = null);
    });
  }

  @override
  Widget build(BuildContext context) => SettingsPane(
        title: null,
        child: ConnectionsHubBody(
          padding: _bodyPadding,
          initialSection: _section,
          wideHeader: true,
        ),
      );
}

class _MydiaInstancePage extends ConsumerWidget {
  const _MydiaInstancePage({required this.sourceId});

  final SourceId sourceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account =
        mydiaAccountFor(ref.watch(sourceRecordsProvider).value, sourceId);
    return SettingsPane(
      title: account?.displayName ?? context.l10n.commonServer,
      child: MydiaInstanceBody(sourceId: sourceId, padding: _bodyPadding),
    );
  }
}

class _AccountDetailPage extends ConsumerWidget {
  const _AccountDetailPage({required this.accountId});

  final String accountId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref
        .watch(sourceRecordsProvider)
        .value
        ?.accounts
        .where((r) => r.account.id == accountId)
        .firstOrNull
        ?.account;
    return SettingsPane(
      title: account?.displayName ?? context.l10n.commonServer,
      child: AccountDetailBody(accountId: accountId, padding: _bodyPadding),
    );
  }
}

/// Settings navigation inside the dialog. Destinations that need the whole
/// window close the dialog before the router takes over, so the dialog never
/// sits over an add-a-server flow or a different source's home.
class DialogSettingsNav implements SettingsNav {
  DialogSettingsNav({required this.scope, required this.router});

  final SettingsDialogScope scope;
  final GoRouter router;

  NavigatorState get _connections =>
      scope.paneNavigator(SettingsCategory.connections);

  @override
  void openInstance(SourceId id) => _connections.push(MaterialPageRoute<void>(
        builder: (_) => _MydiaInstancePage(sourceId: id),
      ));

  @override
  void openDiagnostics() => scope.select(SettingsCategory.diagnostics);

  /// Paired devices are a section of the hub; the dialog returns the pane to
  /// its root and selects it.
  @override
  void openPairedDevices() => scope.connectionsSection.value = 'devices';

  @override
  void openConnections() => scope.select(SettingsCategory.connections);

  @override
  void openAccount(String accountId) =>
      _connections.push(MaterialPageRoute<void>(
        builder: (_) => _AccountDetailPage(accountId: accountId),
      ));

  @override
  void accountRemoved() => _connections.popUntil((route) => route.isFirst);

  @override
  void instanceRemoved() => _connections.popUntil((route) => route.isFirst);

  @override
  void addServer() => _closeThen(() => router.push('/sources/add'));

  @override
  void reauth(SourceKind kind, String accountId) => _closeThen(
      () => router.push('/sources/add/${kind.name}?account=$accountId'));

  @override
  void switchedTo(SourceId id) =>
      _closeThen(() => router.go(sourceHomeLocation(id)));

  void _closeThen(VoidCallback next) {
    scope.close();
    next();
  }
}
