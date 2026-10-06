/// One Mydia instance's settings: what the server is, how this device is
/// registered with it, who else is paired, and removing it from this device.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/compatibility/compatibility_provider.dart';
import '../../../core/compatibility/compatibility_verdict.dart';
import '../../../core/layout/window_chrome_inset.dart';
import '../../../core/remote/node_registration_providers.dart';
import '../../../core/remote/registration_status.dart';
import '../../../core/sources/mydia/mydia_secrets.dart';
import '../../../core/sources/mydia/mydia_source.dart';
import '../../../core/sources/source.dart';
import '../../../core/sources/sources_providers.dart';
import '../../../core/sources/store/source_records.dart';
import '../../../core/theme/colors.dart';
import '../../widgets/toast/toaster.dart';
import '../../widgets/window_chrome/window_title_row.dart';
import '../settings/devices_screen.dart';
import '../settings/widgets/settings_row.dart';
import '../settings/widgets/settings_section.dart';
import 'confirm_remove_account.dart';
import 'manage_sources_screen.dart';

/// What one server says about itself: its version and whether this player and
/// it can work together.
class ServerCompatibility {
  const ServerCompatibility({required this.info, required this.verdict});

  /// Null when the server could not be asked, or predates the declaration.
  final ServerCompatibilityInfo? info;
  final CompatibilityVerdict verdict;
}

/// Resolves to an unknown verdict, never an error, when the server cannot be
/// reached: the screen's other sections still work.
final serverCompatibilityProvider = FutureProvider.autoDispose
    .family<ServerCompatibility, SourceId>((ref, sourceId) async {
  final playerVersion = await ref.watch(playerVersionProvider.future);
  final source = ref.watch(mediaSourceProvider(sourceId));
  final info =
      source is MydiaSource ? await source.client.fetchCompatibility() : null;
  return ServerCompatibility(
    info: info,
    verdict: evaluateCompatibility(playerVersion: playerVersion, server: info),
  );
});

/// Where the instance is reached: its address, or p2p for a paired server.
final mydiaInstanceAddressProvider =
    FutureProvider.autoDispose.family<String?, SourceId>((ref, sourceId) async {
  final account = _accountOf(ref.watch(sourceRecordsProvider).value, sourceId);
  if (account == null) return null;
  final credentials =
      await readMydiaCredentials(ref.watch(sourceSecretsProvider), account);
  return credentials?.serverUrl ??
      (credentials?.isP2p == true ? 'Paired over p2p' : null);
});

ProviderAccount? _accountOf(SourceSnapshot? snapshot, SourceId sourceId) {
  for (final r in snapshot?.accounts ?? const <SourceAccountRecord>[]) {
    if (r.account.kind == SourceKind.mydia && mydiaSourceIdOf(r) == sourceId) {
      return r.account;
    }
  }
  return null;
}

String _verdictLabel(CompatibilityVerdict v) => switch (v) {
      CompatibilityVerdict.compatible => 'Compatible with this player',
      CompatibilityVerdict.playerUpdateRecommended =>
        'A player update is recommended',
      CompatibilityVerdict.playerUpdateRequired =>
        'A player update is required',
      CompatibilityVerdict.serverUpdateRecommended =>
        'A server update is recommended',
      CompatibilityVerdict.serverUpdateRequired =>
        'A server update is required',
      CompatibilityVerdict.unknown => 'Compatibility unknown',
    };

class MydiaInstanceScreen extends ConsumerWidget {
  const MydiaInstanceScreen({super.key, required this.sourceId});

  final SourceId sourceId;

  Future<void> _remove(
    BuildContext context,
    WidgetRef ref,
    ProviderAccount account,
  ) async {
    final router = GoRouter.of(context);
    final toaster = Toaster.of(context);
    try {
      final confirmed = await confirmRemoveAccount(
        context,
        ref,
        account,
        title: 'Remove this server from this device?',
        confirmLabel: 'Remove server',
      );
      if (!confirmed) return;
      await removeMydiaInstance(ref, account);
      // Removing the last or current source can already have sent the router
      // elsewhere (add-a-server); only step back if still on this route.
      final path = router.routerDelegate.currentConfiguration.uri.path;
      if (context.mounted && path.startsWith('/sources/manage/')) {
        router.go('/sources/manage');
      }
    } catch (_) {
      toaster.show('Could not remove this server.', kind: ToastKind.error);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account =
        _accountOf(ref.watch(sourceRecordsProvider).value, sourceId);

    // A full-window route outside the shell, so it owns the title-bar band
    // and sits under `removeBand` itself.
    return WindowChromeInsets.removeBand(
      child: Builder(
        builder: (context) => Scaffold(
          appBar: WindowTitleBar(
            height: WindowTitleRow.heightOf(context),
            leading: const BackButton(),
            title: Text(
              account?.displayName ?? 'Server',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            showCast: false,
            decorate: (row) => ColoredBox(
              color: Theme.of(context).appBarTheme.backgroundColor ??
                  AppColors.background,
              child: row,
            ),
          ),
          body: account == null
              ? const Center(child: Text('This server is no longer saved.'))
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 660),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            KeyedSubtree(
                              key: const Key('mydia-instance-server'),
                              child: _ServerSection(
                                  sourceId: sourceId, account: account),
                            ),
                            const SizedBox(height: 18),
                            KeyedSubtree(
                              key: const Key('mydia-instance-registration'),
                              child: _RegistrationSection(sourceId: sourceId),
                            ),
                            const SizedBox(height: 18),
                            KeyedSubtree(
                              key: const Key('mydia-instance-devices'),
                              child: DevicesSection(sourceId: sourceId),
                            ),
                            const SizedBox(height: 18),
                            SettingsSection(
                              label: 'Remove',
                              children: [
                                SettingsRow.action(
                                  key: const Key('mydia-instance-remove'),
                                  icon: Icons.logout,
                                  title: 'Remove this server',
                                  subtitle: 'Signs out on this device only',
                                  danger: true,
                                  onTap: () => _remove(context, ref, account),
                                ),
                              ],
                            ),
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

class _ServerSection extends ConsumerWidget {
  const _ServerSection({required this.sourceId, required this.account});

  final SourceId sourceId;
  final ProviderAccount account;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final address = ref.watch(mydiaInstanceAddressProvider(sourceId)).value;
    final compat = ref.watch(serverCompatibilityProvider(sourceId));
    final version = compat.value?.info?.version;
    return SettingsSection(
      label: 'Server',
      children: [
        SettingsRow.action(
          icon: Icons.dns_rounded,
          title: account.displayName,
          subtitle: address,
        ),
        SettingsRow.action(
          key: const Key('mydia-instance-version'),
          icon: Icons.info_outline,
          title: switch (compat) {
            AsyncData() => version == null ? 'Version unknown' : 'v$version',
            _ => 'Checking the server',
          },
          subtitle: compat.value == null
              ? null
              : _verdictLabel(compat.value!.verdict),
        ),
      ],
    );
  }
}

class _RegistrationSection extends ConsumerWidget {
  const _RegistrationSection({required this.sourceId});

  final SourceId sourceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(nodeRegistrationsProvider)[sourceId] ??
        const RegistrationIdle();
    return SettingsSection(
      label: 'This device',
      children: [
        SettingsRow.action(
          icon: Icons.settings_remote,
          title: status.describe(),
        ),
        if (status is RegistrationFailed)
          SettingsRow.action(
            key: const Key('mydia-instance-registration-retry'),
            icon: Icons.refresh,
            title: 'Retry registration',
            subtitle: 'Try to make this device discoverable again',
            onTap: () =>
                ref.read(nodeRegistrationsProvider.notifier).retry(sourceId),
          ),
      ],
    );
  }
}
