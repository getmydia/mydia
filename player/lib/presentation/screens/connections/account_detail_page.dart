/// One account's detail page: the per-account controls that used to sit on
/// cards in the Other servers list.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/p2p/p2p_service.dart';
import '../../../core/sources/all_servers_inclusion.dart';
import '../../../core/sources/files/files_account.dart'
    show kFilesLocalAccountId;
import '../../../core/sources/files/files_accounts.dart';
import '../../../core/sources/files/files_providers.dart'
    show filesIndexProvider;
import '../../../core/sources/files/files_scan_controller.dart';
import '../../../core/sources/lock/source_lock_controller.dart';
import '../../../core/sources/mydia/mydia_secrets.dart';
import '../../../core/sources/source.dart';
import '../../../core/sources/sources_providers.dart';
import '../../../core/sources/store/source_records.dart';
import '../../../core/sources/store/source_secrets.dart';
import '../../../l10n/l10n.dart';
import '../../widgets/files/files_scan_banner.dart' show filesScanProgressText;
import '../../widgets/toast/toaster.dart';
import '../settings/settings_nav.dart';
import '../sources/confirm_remove_account.dart';
import '../sources/files_library_kind_picker.dart' show filesLibraryKindLabel;
import '../sources/plex_home_sheet.dart';
import '../sources/source_lock_sheet.dart';
import 'connections_route_scaffold.dart';

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

/// The account detail content, without a `Scaffold`: the mobile page and the
/// desktop settings dialog both host it. Renders nothing for an unknown id.
class AccountDetailBody extends ConsumerWidget {
  const AccountDetailBody({
    super.key,
    required this.accountId,
    this.padding = const EdgeInsets.all(16),
  });

  final String accountId;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final record = _recordFor(ref, accountId);
    if (record == null) return const SizedBox.shrink();
    return ListView(
      padding: padding,
      children: [
        AccountControls(
            record: record, unlocked: ref.watch(sourceLockProvider)),
      ],
    );
  }
}

/// The full-window route, titled with the account's display name.
class AccountDetailPage extends ConsumerWidget {
  const AccountDetailPage({super.key, required this.accountId});

  final String accountId;

  @override
  Widget build(BuildContext context, WidgetRef ref) => ConnectionsRouteScaffold(
        title: _recordFor(ref, accountId)?.account.displayName ?? '',
        body: AccountDetailBody(accountId: accountId),
      );
}

SourceAccountRecord? _recordFor(WidgetRef ref, String accountId) => ref
    .watch(sourceRecordsProvider)
    .value
    ?.accounts
    .where((r) => r.account.id == accountId)
    .firstOrNull;

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

/// A files account's folders, each removable, and a Rescan of them all.
class _FilesRoots extends ConsumerStatefulWidget {
  const _FilesRoots({required this.source});

  final Source source;

  @override
  ConsumerState<_FilesRoots> createState() => _FilesRootsState();
}

class _FilesRootsState extends ConsumerState<_FilesRoots> {
  Future<void> _removeRoot(String rootId) async {
    final toaster = Toaster.of(context);
    final l10n = context.l10n;
    try {
      await ref
          .read(filesAccountsProvider)
          .removeRoot(widget.source.id, rootId);
    } catch (e) {
      debugPrint('[Sources] Could not remove folder $rootId: $e');
      toaster.show(l10n.sourcesRemoveAccountFailed, kind: ToastKind.error);
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final source = widget.source;
    final roots = ref.watch(filesIndexProvider(source.account.id)).roots()
      ..sort((a, b) => a.title.compareTo(b.title));
    final scan = ref.watch(filesScanProvider(source.id));
    final scanning = scan.running;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final root in roots)
          ListTile(
            key: ValueKey('manage-root-${root.id}'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.folder_rounded),
            title: Text(root.title),
            subtitle: Text(context.l10n.filesManageRootSubtitle(
                filesLibraryKindLabel(context.l10n, root.kind), root.path)),
            trailing: IconButton(
              key: ValueKey('manage-remove-root-${root.id}'),
              tooltip: context.l10n.filesManageRemoveFolder,
              icon: const Icon(Icons.remove_circle_outline_rounded),
              onPressed: () => _removeRoot(root.id),
            ),
          ),
        TextButton.icon(
          key: ValueKey('manage-rescan-${source.account.id}'),
          onPressed: scanning || roots.isEmpty
              ? null
              : () => unawaited(ref
                      .read(filesScanProvider(source.id).notifier)
                      .rescan()
                      .catchError((Object e) {
                    debugPrint('[Sources] Rescan failed: $e');
                  })),
          // A disabled Rescan alone reads as broken: while a scan runs, the
          // button says how far it has got.
          icon: scanning
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.refresh_rounded),
          label: Text(scanning
              ? filesScanProgressText(context.l10n, scan)
              : context.l10n.filesManageRescan),
        ),
      ],
    );
  }
}

/// One account's controls: its servers (lock, All servers), folders, and the
/// reauth and remove actions. The account detail page and the interim
/// Other servers list both host it.
class AccountControls extends ConsumerWidget {
  const AccountControls(
      {super.key, required this.record, required this.unlocked});

  final SourceAccountRecord record;
  final bool unlocked;

  Future<void> _remove(BuildContext context, WidgetRef ref) async {
    // Taken before the awaits: removing the record can unmount this widget.
    final nav = SettingsNavScope.of(context);
    final confirmed = await confirmRemoveAccount(context, ref, record.account);
    if (!confirmed || !context.mounted) return;
    final toaster = Toaster.of(context);
    final l10n = context.l10n;
    try {
      if (record.account.kind == SourceKind.files) {
        await ref
            .read(filesAccountsProvider)
            .removeFilesAccount(record.account.id);
      } else {
        await removeMydiaInstance(ref, record.account);
      }
    } catch (_) {
      toaster.show(l10n.sourcesRemoveAccountFailed, kind: ToastKind.error);
      return;
    }
    nav.accountRemoved();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = record.account;
    return Column(
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
              SourceKind.files => context.l10n.sourcesAccountFiles,
            },
            style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 8),
        for (final server in record.servers)
          if (unlocked || record.lockOf(server.id) != SourceLock.hidden) ...[
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
                onPressed: () => changeServerLock(context, ref, record, server),
              ),
            ),
            // A server that is gone has no source, hence no switch.
            if (record.sources
                    .where((s) => s.server.id == server.id)
                    .firstOrNull
                case final source?)
              _AllServersSwitch(source: source),
          ],
        if (account.kind == SourceKind.files)
          if (record.sources.firstOrNull case final source?)
            _FilesRoots(source: source),
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
            if (account.kind == SourceKind.plex && record.profiles.length > 1)
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
              onPressed: () =>
                  SettingsNavScope.of(context).reauth(account.kind, account.id),
              child: Text(switch ((account.kind, account.needsReauth)) {
                (SourceKind.files, final reauth)
                    when account.id == kFilesLocalAccountId =>
                  reauth
                      ? context.l10n.filesChooseFolderAgain
                      : context.l10n.filesManageAddFolder,
                (_, true) => context.l10n.navSourceSignInAgain,
                (SourceKind.plex, _) => context.l10n.sourcesReauthPlex,
                (SourceKind.jellyfin, _) => context.l10n.sourcesReauthJellyfin,
                (SourceKind.files, _) => context.l10n.filesManageEditShare,
                (SourceKind.stash || SourceKind.mydia, _) =>
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
    );
  }
}
