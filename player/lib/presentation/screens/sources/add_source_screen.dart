library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/player/input_capabilities.dart';
import '../../../core/sources/lock/source_lock_controller.dart';
import '../../../core/sources/sources_providers.dart';
import '../../../l10n/l10n.dart';
import '../backup/restore_backup_screen.dart' show restoreBackupLocation;
import '../settings/widgets/settings_row.dart';
import '../settings/widgets/settings_section.dart';
import 'add_folder_screen.dart' show localFoldersSupported;

class AddSourceScreen extends ConsumerWidget {
  const AddSourceScreen(
      {super.key,
      this.isWeb = kIsWeb,
      this.foldersSupported,
      this.directionalPrimary});

  /// Third-party sources do not exist on web, so a second Mydia added there
  /// would vanish. Overridable for tests.
  final bool isWeb;

  /// Whether Folder is offered; [localFoldersSupported] when null.
  /// Overridable for tests.
  final bool? foldersSupported;

  /// Overrides [InputCapabilities.directionalPrimary], which tests cannot set.
  /// On a television the first enabled row takes focus; elsewhere none does.
  final bool? directionalPrimary;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final hasMydia = ref.watch(hasMydiaProvider);
    final guestsUnavailable = hasMydia && isWeb;
    final remote = directionalPrimary ?? InputCapabilities.directionalPrimary;
    void open(String location) => context.push(location);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.sourcesAddTitle)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 660),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // No label: it would only repeat the row's own title.
                  SettingsCard(
                    children: [
                      SettingsRow.navigation(
                        key: const Key('add-source-mydia'),
                        icon: Icons.dns_rounded,
                        title: 'Mydia', // l10n-ignore: product name
                        subtitle: switch ((hasMydia, guestsUnavailable)) {
                          (true, true) => l10n.sourcesAddMydiaOnlyInApps,
                          (true, false) => l10n.sourcesAddMydiaShared,
                          _ => l10n.sourcesAddMydiaSignIn,
                        },
                        // A null callback dims the row and drops it from
                        // the focus order.
                        onTap: guestsUnavailable
                            ? null
                            : () => open('/sources/add/mydia'),
                        autofocus: remote && !guestsUnavailable,
                      ),
                    ],
                  ),
                  _gap,
                  SettingsSection(
                    label: l10n.sourcesAddSectionServers,
                    children: [
                      SettingsRow.navigation(
                        key: const Key('add-source-plex'),
                        icon: Icons.live_tv_rounded,
                        title: 'Plex', // l10n-ignore: product name
                        subtitle: l10n.sourcesAddPlexSubtitle,
                        onTap: () => open('/sources/add/plex'),
                        autofocus: remote && guestsUnavailable,
                      ),
                      SettingsRow.navigation(
                        key: const Key('add-source-jellyfin'),
                        icon: Icons.smart_display_rounded,
                        title: 'Jellyfin', // l10n-ignore: product name
                        subtitle: l10n.sourcesAddJellyfinSubtitle,
                        onTap: () => open('/sources/add/jellyfin'),
                      ),
                      SettingsRow.navigation(
                        key: const Key('add-source-stash'),
                        icon: Icons.video_library_rounded,
                        title: 'Stash', // l10n-ignore: product name
                        subtitle: l10n.sourcesAddStashSubtitle,
                        onTap: () => open('/sources/add/stash'),
                      ),
                    ],
                  ),
                  if (!isWeb) ...[
                    _gap,
                    SettingsSection(
                      label: l10n.sourcesAddSectionFiles,
                      children: [
                        if (foldersSupported ?? localFoldersSupported)
                          SettingsRow.navigation(
                            key: const Key('add-source-folder'),
                            icon: Icons.folder_rounded,
                            title: l10n.sourcesAddFolderTitle,
                            subtitle: l10n.sourcesAddFolderSubtitle,
                            onTap: () => open('/sources/add/folder'),
                          ),
                        SettingsRow.navigation(
                          key: const Key('add-source-webdav'),
                          icon: Icons.folder_shared_rounded,
                          title: 'WebDAV', // l10n-ignore: protocol name
                          subtitle: l10n.sourcesAddWebDavSubtitle,
                          onTap: () => open('/sources/add/webdav'),
                        ),
                        SettingsRow.navigation(
                          key: const Key('add-source-smb'),
                          icon: Icons.lan_rounded,
                          title: 'SMB', // l10n-ignore: protocol name
                          subtitle: l10n.sourcesAddSmbSubtitle,
                          onTap: () => open('/sources/add/smb'),
                        ),
                        SettingsRow.navigation(
                          key: const Key('add-source-s3'),
                          icon: Icons.cloud_rounded,
                          title: 'S3', // l10n-ignore: protocol name
                          subtitle: l10n.sourcesAddS3Subtitle,
                          onTap: () => open('/sources/add/s3'),
                        ),
                      ],
                    ),
                    _gap,
                    SettingsSection(
                      label: l10n.sourcesAddSectionBackup,
                      children: [
                        SettingsRow.navigation(
                          key: const Key('add-source-restore'),
                          icon: Icons.settings_backup_restore_rounded,
                          title: l10n.backupRestoreTitle,
                          subtitle: l10n.backupRestoreSubtitle,
                          onTap: () => open(restoreBackupLocation),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  static const _gap = SizedBox(height: 24);
}

/// Under the login form: a way in for someone with no Mydia server.
class ConnectOtherServerButton extends StatelessWidget {
  const ConnectOtherServerButton({super.key});

  @override
  Widget build(BuildContext context) {
    if (kIsWeb) return const SizedBox.shrink();
    return TextButton.icon(
      key: const Key('connect-other-server'),
      onPressed: () => context.push('/sources/add'),
      icon: const Icon(Icons.add_link),
      label: Text(context.l10n.sourcesConnectOtherServer),
    );
  }
}

/// Under the login form too: with every server hidden and no Mydia, this is
/// the only way back to them.
class ShowHiddenSourcesButton extends StatelessWidget {
  const ShowHiddenSourcesButton({super.key});

  @override
  Widget build(BuildContext context) {
    if (kIsWeb) return const SizedBox.shrink();
    return TextButton.icon(
      key: const Key('show-hidden-sources-login'),
      onPressed: () => context.push(unlockLocation('/sources/manage')),
      icon: const Icon(Icons.visibility_rounded),
      label: Text(context.l10n.navShowHiddenServers),
    );
  }
}
