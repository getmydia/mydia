import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/connection/connection_summary.dart';
import '../../../core/layout/dock_insets.dart';
import '../../../core/layout/window_chrome_inset.dart';
import '../../../core/p2p/p2p_service.dart';
import '../../../core/update/update_provider.dart';
import '../../widgets/ambient_backdrop_provider.dart';
import '../../widgets/connection_tone_color.dart';
import '../../widgets/window_chrome/window_title_row.dart';
import '../sources/manage_sources_screen.dart';
import 'settings_controller.dart';
import 'settings_nav.dart';
import '../../../core/sources/mydia/source_link.dart';
import '../../../core/sources/sources_providers.dart'
    show activeSourceIdProvider, mydiaAccountCountProvider;
import 'widgets/settings_identity.dart';
import 'widgets/settings_row.dart';
import 'widgets/settings_section.dart';
import 'widgets/settings_sections.dart';
import 'widgets/update_card.dart';

export 'widgets/settings_sections.dart' show updateCheckSubtitle;

/// The settings screen.
///
/// Read-only facts live in the hero; everything below it is something you can
/// change or somewhere you can go. The old screen gave a relay URL and a logout
/// button identical tiles, which is what this split fixes.
///
/// Sections fail independently. A preferences read that fails must not take the
/// screen down with it: someone opening settings while something is broken is
/// quite likely there to sign out or collect diagnostics.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  /// Builds Settings' title-bar header.
  ///
  /// A static, `@visibleForTesting` seam rather than inlined in [build]:
  /// `build` also wires up `settingsControllerProvider`, `sourceViaP2pProvider`,
  /// `p2pStatusNotifierProvider` (which starts a real native P2P node) and
  /// `updateProvider`, all far too expensive to satisfy in a widget test that
  /// only wants to check where the cast button lands. This is the exact
  /// widget [build] puts in `Scaffold.appBar`, not a mirror of it.
  @visibleForTesting
  static PreferredSizeWidget header(BuildContext context) {
    return WindowTitleBar(
      height: WindowTitleRow.heightOf(context),
      title: Text('Settings', style: Theme.of(context).textTheme.titleLarge),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settingsAsync = ref.watch(settingsControllerProvider);
    final activeId = ref.watch(activeSourceIdProvider);
    final isP2P = activeId != null &&
        (ref.watch(sourceViaP2pProvider(activeId)).value ?? false);
    final p2pStatus = ref.watch(p2pStatusNotifierProvider);
    final currentVersion = ref.watch(updateProvider).currentVersion;
    final manyMydiaAccounts = ref.watch(mydiaAccountCountProvider) > 1;

    // Settings shows the calm static backdrop, never a stale title image
    // (plan U5 / AE3).
    publishBackdropSource(ref, BackdropSource.none);

    // Riverpod 3 renamed valueOrNull to value (nullable).
    final settings = settingsAsync.value;
    final summary = ConnectionSummary.from(
      isP2P: isP2P,
      type: p2pStatus.peerConnectionType,
      isInitialized: p2pStatus.isInitialized,
    );
    final horizontal = MediaQuery.sizeOf(context).width >= 600 ? 26.0 : 14.0;

    // Settings sits in the shell's content column, whose leading inset the
    // shell already narrows by the sidebar width, so its own `WindowTitleRow`
    // (via `WindowTitleBar`, below) draws into the band directly rather than
    // going through a separate desktop cast overlay. The body has to sit
    // under `removeBand`, or the ambient `MediaQuery.padding.top` still
    // carries the band on top of the app bar's own reserved height.
    return WindowChromeInsets.removeBand(
      child: Builder(
        builder: (context) => Scaffold(
          backgroundColor: Colors.transparent,
          appBar: header(context),
          // An explicit padding turns off ListView's own MediaQuery bottom
          // inset, so the dock's height has to be reserved here by hand.
          body: ListView(
            padding: EdgeInsets.fromLTRB(
              horizontal,
              20,
              horizontal,
              DockInsets.bottomOf(context),
            ),
            children: [
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 660),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // With several Mydia accounts this would name only the
                      // bound one; each instance's own screen carries it.
                      if (!manyMydiaAccounts)
                        SettingsIdentity(
                          username: settings?.username ?? '',
                          serverUrl: settings?.serverUrl ?? '',
                        ),
                      const UpdateCard(),
                      PlaybackSettingsSection(
                        settings: settings,
                        failed: settingsAsync.hasError,
                      ),
                      const SizedBox(height: 18),
                      const AppearanceSettingsSection(),
                      const SizedBox(height: 18),
                      _ManageSection(connection: summary),
                      const SizedBox(height: 18),
                      const SourcesSettingsSection(),
                      VersionFooter(version: currentVersion),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ManageSection extends ConsumerWidget {
  const _ManageSection({required this.connection});

  final ConnectionSummary connection;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SettingsSection(
      label: 'Manage',
      children: [
        SettingsRow.navigation(
          icon: Icons.lan_outlined,
          title: 'Diagnostics',
          subtitle: connection.label,
          subtitleDotColor: connectionToneColor(connection.tone),
          onTap: () => SettingsNavScope.of(context).openDiagnostics(),
        ),
        ...remoteControlRows(context, ref),
        ...updateRows(context, ref),
      ],
    );
  }
}
