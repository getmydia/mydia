library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/downloads/download_providers.dart';
import '../../../core/downloads/download_service.dart';
import '../../../core/p2p/p2p_service.dart';
import '../../../core/sources/all_servers_inclusion.dart';
import '../../../core/sources/lock/source_lock_controller.dart';
import '../../../core/sources/mydia/mydia_secrets.dart';
import '../../../core/sources/source.dart';
import '../../../core/sources/sources_providers.dart';
import '../../../core/sources/store/source_records.dart';
import '../../../core/sources/store/source_secrets.dart';
import '../../../domain/models/download.dart';
import '../../widgets/toast/toaster.dart';
import '../detail/detail_links.dart';
import '../settings/widgets/settings_row.dart';
import '../settings/widgets/settings_section.dart';
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

class ManageSourcesScreen extends ConsumerWidget {
  const ManageSourcesScreen({super.key});

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
    return Scaffold(
      appBar: AppBar(
        title: const Text('Other servers'),
        actions: [
          TextButton.icon(
            key: const Key('manage-add'),
            onPressed: () => context.push('/sources/add'),
            icon: const Icon(Icons.add),
            label: const Text('Add server'),
          ),
        ],
      ),
      body: switch (records) {
        AsyncData(:final value) when visible(value).isEmpty => ListView(
            padding: const EdgeInsets.all(16),
            children: const [
              Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: Text('No servers yet.')),
              ),
              ShowHiddenSourcesRow(),
            ],
          ),
        AsyncData(:final value) => ListView(
            padding: const EdgeInsets.all(16),
            children: [
              for (final record in visible(value))
                _AccountCard(
                    key: ValueKey(record.account.id),
                    record: record,
                    unlocked: unlocked),
              const ShowHiddenSourcesRow(),
            ],
          ),
        AsyncError() =>
          const Center(child: Text('Could not read the saved servers.')),
        _ => const Center(child: CircularProgressIndicator()),
      },
    );
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
        title: const Text('Include in All servers'),
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
    var footprint = (count: 0, bytes: 0);
    if (isDownloadSupported) {
      try {
        footprint = (await ref
                .read(downloadManagerProvider.future)
                .timeout(downloadLookupTimeout))
            .accountDownloads(record.account.id);
      } catch (_) {
        // The dialog still works without the count.
      }
    }
    if (!context.mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove this account?'),
        content: Text('${record.account.displayName} and its servers are '
            'removed from this device. Nothing changes on the server.'
            '${footprint.count == 0 ? '' : '\n\nThis also deletes ${footprint.count} '
                'download${footprint.count == 1 ? '' : 's'} '
                '(${DownloadTask.formatBytes(footprint.bytes)}).'}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const Key('manage-remove-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final toaster = Toaster.of(context);
    try {
      await removeMydiaInstance(ref, record.account);
    } catch (_) {
      toaster.show('Could not remove this account.', kind: ToastKind.error);
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
                  SourceKind.plex => 'Plex account',
                  SourceKind.stash => 'Stash server',
                  SourceKind.jellyfin => 'Jellyfin user',
                  SourceKind.mydia => 'Mydia account',
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
                      ? const Text('No longer on this account')
                      : (!server.presence ? const Text('Offline') : null),
                  trailing: IconButton(
                    key: Key('manage-lock-${server.id}'),
                    tooltip: 'Lock',
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
              children: [
                if (account.kind == SourceKind.plex &&
                    record.profiles.length > 1)
                  OutlinedButton(
                    key: Key('manage-switch-user-${account.id}'),
                    onPressed: () => showPlexHomeSheet(
                      context,
                      account: account,
                      onSwitched: (id) => context.go(sourceHomeLocation(id)),
                    ),
                    child: const Text('Switch user'),
                  ),
                OutlinedButton(
                  key: Key('manage-reauth-${account.id}'),
                  onPressed: () => context.push(
                      '/sources/add/${account.kind.name}?account=${account.id}'),
                  child: Text(account.needsReauth
                      ? 'Sign in again'
                      : switch (account.kind) {
                          SourceKind.plex => 'Sign in again or choose servers',
                          SourceKind.jellyfin => 'Change address or sign in',
                          SourceKind.stash ||
                          SourceKind.mydia =>
                            'Change address or key',
                        }),
                ),
                TextButton(
                  key: Key('manage-remove-${account.id}'),
                  onPressed: () => _remove(context, ref),
                  child: const Text('Remove'),
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
      label: 'Other servers',
      children: [
        SettingsRow.navigation(
          key: const Key('manage-sources-row'),
          icon: Icons.dns_rounded,
          title: 'Plex, Jellyfin and Stash',
          subtitle: 'Add or remove servers',
          onTap: () => context.push('/sources/manage'),
        ),
      ],
    );
  }
}
