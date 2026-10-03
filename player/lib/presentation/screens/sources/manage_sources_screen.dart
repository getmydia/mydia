library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/sources/sources_providers.dart';
import '../../../core/sources/store/source_records.dart';
import '../settings/widgets/settings_row.dart';
import '../settings/widgets/settings_section.dart';

class ManageSourcesScreen extends ConsumerWidget {
  const ManageSourcesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final records = ref.watch(sourceRecordsProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Plex and Stash servers'),
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
        AsyncData(:final value) when value.accounts.isEmpty => const Center(
            child: Text('No Plex or Stash servers yet.'),
          ),
        AsyncData(:final value) => ListView(
            padding: const EdgeInsets.all(16),
            children: [
              for (final record in value.accounts)
                _AccountCard(key: ValueKey(record.account.id), record: record),
            ],
          ),
        AsyncError() =>
          const Center(child: Text('Could not read the saved servers.')),
        _ => const Center(child: CircularProgressIndicator()),
      },
    );
  }
}

class _AccountCard extends ConsumerWidget {
  const _AccountCard({super.key, required this.record});

  final SourceAccountRecord record;

  Future<void> _remove(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove this account?'),
        content: Text('${record.account.displayName} and its servers are '
            'removed from this device. Nothing changes on the server.'),
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
    if (confirmed != true) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(sourceRecordsProvider.notifier)
          .removeAccount(record.account.id);
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not remove this account.')),
      );
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
            Text(account.kind.name == 'plex' ? 'Plex account' : 'Stash server',
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
            for (final server in record.servers)
              ListTile(
                key: ValueKey('manage-server-${server.id}'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(server.name),
                subtitle: server.gone
                    ? const Text('No longer on this account')
                    : (!server.presence ? const Text('Offline') : null),
              ),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton(
                  key: Key('manage-reauth-${account.id}'),
                  onPressed: () => context.push(
                      '/sources/add/${account.kind.name}?account=${account.id}'),
                  child: Text(account.needsReauth
                      ? 'Sign in again'
                      : (account.kind.name == 'plex'
                          ? 'Sign in again or choose servers'
                          : 'Change address or key')),
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
          title: 'Plex and Stash',
          subtitle: 'Add or remove servers',
          onTap: () => context.push('/sources/manage'),
        ),
      ],
    );
  }
}
