/// What each settings category shows inside the desktop dialog, and how its
/// rows navigate there.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/sources/source.dart';
import '../../../../core/sources/sources_providers.dart';
import '../../detail/detail_links.dart';
import '../../sources/manage_sources_screen.dart';
import '../../sources/mydia_instance_screen.dart';
import '../diagnostics_screen.dart';
import '../settings_controller.dart';
import '../settings_nav.dart';
import '../widgets/settings_sections.dart';
import 'settings_dialog.dart';

const _bodyPadding = EdgeInsets.fromLTRB(24, 8, 24, 24);

Widget settingsRootPage(SettingsCategory category) => switch (category) {
      SettingsCategory.playback => const _PlaybackPage(),
      SettingsCategory.servers => const SettingsPane(
          title: 'Servers',
          child: ManageSourcesBody(padding: _bodyPadding),
        ),
      SettingsCategory.diagnostics => const SettingsPane(
          title: 'Diagnostics',
          child: DiagnosticsBody(padding: _bodyPadding),
        ),
      SettingsCategory.about => SettingsPane(
          title: 'About',
          child: ListView(
            padding: _bodyPadding,
            children: const [AboutSettingsSection()],
          ),
        ),
    };

class _PlaybackPage extends ConsumerWidget {
  const _PlaybackPage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsControllerProvider);
    return SettingsPane(
      title: 'Playback',
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

class _MydiaInstancePage extends ConsumerWidget {
  const _MydiaInstancePage({required this.sourceId});

  final SourceId sourceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account =
        mydiaAccountFor(ref.watch(sourceRecordsProvider).value, sourceId);
    return SettingsPane(
      title: account?.displayName ?? 'Server',
      child: MydiaInstanceBody(sourceId: sourceId, padding: _bodyPadding),
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

  NavigatorState get _servers => scope.paneNavigator(SettingsCategory.servers);

  @override
  void openInstance(SourceId id) => _servers.push(MaterialPageRoute<void>(
        builder: (_) => _MydiaInstancePage(sourceId: id),
      ));

  @override
  void openDiagnostics() => scope.select(SettingsCategory.diagnostics);

  @override
  void instanceRemoved() => _servers.popUntil((route) => route.isFirst);

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
