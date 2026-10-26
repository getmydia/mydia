library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/p2p/p2p_service.dart';
import '../../../core/sources/all_servers_inclusion.dart';
import '../../../core/sources/lock/source_lock_controller.dart';
import '../../../core/sources/mydia/mydia_secrets.dart';
import '../../../core/sources/source.dart';
import '../../../core/sources/sources_providers.dart';
import '../../../core/sources/store/source_records.dart';
import '../../../core/sources/store/source_secrets.dart';
import '../../../l10n/l10n.dart';
import '../../widgets/toast/toaster.dart';
import '../settings/settings_nav.dart';
import '../settings/widgets/settings_row.dart';
import '../settings/widgets/settings_section.dart';
import 'confirm_remove_account.dart';
import 'plex_home_sheet.dart';
import 'source_lock_sheet.dart';

/// A Mydia reached over p2p stops being watched. Unreadable credentials
/// must not block the removal.
Future<void> unwatchMydiaPeer(
  SourceSecrets secrets,
  P2pService p2p,
  ProviderAccount account,
) async {
  if (account.kind != SourceKind.mydia) return;
  try {
    final nodeAddr = (await readMydiaCredentials(secrets, account))?.nodeAddr;
    if (nodeAddr != null) p2p.unwatchPeer(nodeAddr);
  } catch (e) {
    debugPrint('[Sources] Could not stop watching the peer: $e');
  }
}

/// Removes a Mydia instance from this device: stops watching its peer, then
/// drops the account and everything stored for it. Nothing changes on the
/// server.
Future<void> removeMydiaInstance(WidgetRef ref, ProviderAccount account) async {
  await unwatchMydiaPeer(
      ref.read(sourceSecretsProvider), ref.read(p2pServiceProvider), account);
  await ref.read(sourceRecordsProvider.notifier).removeAccount(account.id);
}

class ManageSourcesScreen extends StatelessWidget {
  const ManageSourcesScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: Text(context.l10n.sourcesOtherServers),
          actions: [
            AddServerButton(
                onPressed: () => SettingsNavScope.of(context).addServer()),
          ],
        ),
        body: const ManageSourcesBody(showAddButton: false),
      );
}

/// The `manage-add` button, in the mobile app bar or at the top of the
/// dialog's Servers pane.
class AddServerButton extends StatelessWidget {
  const AddServerButton({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => TextButton.icon(
        key: const Key('manage-add'),
        onPressed: onPressed,
        icon: const Icon(Icons.add),
        label: Text(context.l10n.navAddServer),
      );
}

/// The saved servers, without a `Scaffold`: the mobile screen and the desktop
/// settings dialog both host it.
class ManageSourcesBody extends ConsumerWidget {
  const ManageSourcesBody({
    super.key,
    this.padding = const EdgeInsets.all(16),
    this.showAddButton = true,
  });

  final EdgeInsets padding;

  /// False where the host already shows [AddServerButton], as the mobile app
  /// bar does.
  final bool showAddButton;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final records = ref.watch(sourceRecordsProvider);
    final unlocked = ref.watch(sourceLockProvider);
    List<SourceAccountRecord> visible(SourceSnapshot s) => [
          for (final r in s.accounts)
            if (unlocked ||
                r.servers.isEmpty ||
                r.servers.any((sv) => r.lockOf(sv.id) != SourceLock.hidden))
              r,
        ];
    final addButton = showAddButton
        ? Align(
            alignment: Alignment.centerRight,
            child: AddServerButton(
                onPressed: () => SettingsNavScope.of(context).addServer()),
          )
        : null;
    return switch (records) {
      AsyncData(:final value) when visible(value).isEmpty => ListView(
          padding: padding,
          children: [
            if (addButton != null) addButton,
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Center(child: Text(context.l10n.sourcesNoServers)),
            ),
            const ShowHiddenSourcesRow(),
          ],
        ),
      AsyncData(:final value) => ListView(
          padding: padding,
          children: [
            if (addButton != null) addButton,
            for (final record in visible(value))
              _AccountCard(
                  key: ValueKey(record.account.id),
                  record: record,
                  unlocked: unlocked),
            const ShowHiddenSourcesRow(),
          ],
        ),
      AsyncError() => Center(child: Text(context.l10n.sourcesLoadFailed)),
      _ => const Center(child: CircularProgressIndicator()),
    };
  }
}

/// The "Include in All servers" switch for one source.
class _AllServersSwitch extends ConsumerWidget {
  const _AllServersSwitch({required this.source});

  final Source source;

  @override
  Widget build(BuildContext context, WidgetRef ref) => SwitchListTile(
        key: ValueKey('manage-all-servers-${source.id.value}'),
        dense: true,
        contentPadding: EdgeInsets.zero,
        title: Text(context.l10n.sourcesIncludeInAll),
        value:
            includedInAllServers(source, ref.watch(allServersChoicesProvider)),
        onChanged: (on) => ref
            .read(sourceRecordsProvider.notifier)
            .setIncludedInAllServers(source.id, on),
      );
}

class _AccountCard extends ConsumerWidget {
  const _AccountCard({super.key, required this.record, required this.unlocked});

  final SourceAccountRecord record;
  final bool unlocked;

  Future<void> _remove(BuildContext context, WidgetRef ref) async {
    final confirmed = await confirmRemoveAccount(context, ref, record.account);
    if (!confirmed || !context.mounted) return;
    final toaster = Toaster.of(context);
    final l10n = context.l10n;
    try {
      await removeMydiaInstance(ref, record.account);
    } catch (_) {
      toaster.show(l10n.sourcesRemoveAccountFailed, kind: ToastKind.error);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = record.account;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(account.displayName,
                style: Theme.of(context).textTheme.titleMedium),
            Text(
                switch (account.kind) {
                  SourceKind.plex => context.l10n.sourcesAccountPlex,
                  SourceKind.stash => context.l10n.sourcesAccountStash,
                  SourceKind.jellyfin => context.l10n.sourcesAccountJellyfin,
                  SourceKind.mydia => context.l10n.sourcesAccountMydia,
                },
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
            for (final server in record.servers)
              if (unlocked ||
                  record.lockOf(server.id) != SourceLock.hidden) ...[
                ListTile(
                  key: ValueKey('manage-server-${server.id}'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(server.name),
                  subtitle: server.gone
                      ? Text(context.l10n.sourcesServerGone)
                      : (!server.presence
                          ? Text(context.l10n.commonOffline)
                          : null),
                  trailing: IconButton(
                    key: Key('manage-lock-${server.id}'),
                    tooltip: context.l10n.sourcesLockTooltip,
                    icon: Icon(switch (record.lockOf(server.id)) {
                      SourceLock.none => Icons.lock_open_rounded,
                      SourceLock.locked => Icons.lock_rounded,
                      SourceLock.hidden => Icons.visibility_off_rounded,
                    }),
                    onPressed: () =>
                        changeServerLock(context, ref, record, server),
                  ),
                ),
                // A server that is gone has no source, hence no switch.
                if (record.sources
                        .where((s) => s.server.id == server.id)
                        .firstOrNull
                    case final source?)
                  _AllServersSwitch(source: source),
              ],
            Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (account.kind == SourceKind.mydia)
                  IconButton(
                    key: Key('manage-settings-${account.id}'),
                    tooltip: context.l10n.settingsTitle,
                    icon: const Icon(Icons.settings_rounded),
                    onPressed: () => SettingsNavScope.of(context)
                        .openInstance(mydiaSourceIdOf(record)),
                  ),
                if (account.kind == SourceKind.plex &&
                    record.profiles.length > 1)
                  OutlinedButton(
                    key: Key('manage-switch-user-${account.id}'),
                    onPressed: () => showPlexHomeSheet(
                      context,
                      account: account,
                      onSwitched: (id) =>
                          SettingsNavScope.of(context).switchedTo(id),
                    ),
                    child: Text(context.l10n.sourcesSwitchUser),
                  ),
                OutlinedButton(
                  key: Key('manage-reauth-${account.id}'),
                  onPressed: () => SettingsNavScope.of(context)
                      .reauth(account.kind, account.id),
                  child: Text(account.needsReauth
                      ? context.l10n.navSourceSignInAgain
                      : switch (account.kind) {
                          SourceKind.plex => context.l10n.sourcesReauthPlex,
                          SourceKind.jellyfin =>
                            context.l10n.sourcesReauthJellyfin,
                          SourceKind.stash ||
                          SourceKind.mydia =>
                            context.l10n.sourcesReauthKey,
                        }),
                ),
                TextButton(
                  key: Key('manage-remove-${account.id}'),
                  onPressed: () => _remove(context, ref),
                  child: Text(context.l10n.commonRemove),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The settings entry, so a Mydia user with no second server yet can find
/// where to add one.
class SourcesSettingsSection extends StatelessWidget {
  const SourcesSettingsSection({super.key});

  @override
  Widget build(BuildContext context) {
    if (kIsWeb) return const SizedBox.shrink();
    return SettingsSection(
      label: context.l10n.sourcesOtherServers,
      children: [
        SettingsRow.navigation(
          key: const Key('manage-sources-row'),
          icon: Icons.dns_rounded,
          title: context.l10n.sourcesSettingsRowTitle,
          subtitle: context.l10n.sourcesSettingsRowSubtitle,
          onTap: () => context.push('/sources/manage'),
        ),
      ],
    );
  }
}
