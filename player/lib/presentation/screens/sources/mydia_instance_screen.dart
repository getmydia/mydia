/// One Mydia instance's settings: what the server is, how this device is
/// registered with it, who else is paired, and removing it from this device.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
import '../../../core/theme/palette.dart';
import '../../../l10n/l10n.dart';
import '../../widgets/toast/toaster.dart';
import '../../widgets/window_chrome/window_title_row.dart';
import '../settings/devices_screen.dart';
import '../settings/settings_nav.dart';
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
sealed class MydiaInstanceAddress {
  const MydiaInstanceAddress();
}

final class MydiaInstanceUrl extends MydiaInstanceAddress {
  const MydiaInstanceUrl(this.url);

  final String url;
}

final class MydiaInstanceP2p extends MydiaInstanceAddress {
  const MydiaInstanceP2p();
}

final mydiaInstanceAddressProvider = FutureProvider.autoDispose
    .family<MydiaInstanceAddress?, SourceId>((ref, sourceId) async {
  final account =
      mydiaAccountFor(ref.watch(sourceRecordsProvider).value, sourceId);
  if (account == null) return null;
  final credentials =
      await readMydiaCredentials(ref.watch(sourceSecretsProvider), account);
  final url = credentials?.serverUrl;
  if (url != null) return MydiaInstanceUrl(url);
  return credentials?.isP2p == true ? const MydiaInstanceP2p() : null;
});

ProviderAccount? mydiaAccountFor(SourceSnapshot? snapshot, SourceId sourceId) {
  for (final r in snapshot?.accounts ?? const <SourceAccountRecord>[]) {
    if (r.account.kind == SourceKind.mydia && mydiaSourceIdOf(r) == sourceId) {
      return r.account;
    }
  }
  return null;
}

String _verdictLabel(AppLocalizations l10n, CompatibilityVerdict v) =>
    switch (v) {
      CompatibilityVerdict.compatible => l10n.sourcesInstanceCompatible,
      CompatibilityVerdict.playerUpdateRecommended =>
        l10n.sourcesInstancePlayerUpdateRecommended,
      CompatibilityVerdict.playerUpdateRequired =>
        l10n.sourcesInstancePlayerUpdateRequired,
      CompatibilityVerdict.serverUpdateRecommended =>
        l10n.sourcesInstanceServerUpdateRecommended,
      CompatibilityVerdict.serverUpdateRequired =>
        l10n.sourcesInstanceServerUpdateRequired,
      CompatibilityVerdict.unknown => l10n.sourcesInstanceCompatibilityUnknown,
    };

class MydiaInstanceScreen extends StatelessWidget {
  const MydiaInstanceScreen({super.key, required this.sourceId});

  final SourceId sourceId;

  @override
  Widget build(BuildContext context) {
    // A full-window route outside the shell, so it owns the title-bar band
    // and sits under `removeBand` itself.
    return WindowChromeInsets.removeBand(
      child: Builder(
        builder: (context) => Consumer(
          builder: (context, ref, _) {
            final account = mydiaAccountFor(
                ref.watch(sourceRecordsProvider).value, sourceId);
            return Scaffold(
              appBar: WindowTitleBar(
                height: WindowTitleRow.heightOf(context),
                leading: const BackButton(),
                title: Text(
                  account?.displayName ?? context.l10n.commonServer,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                decorate: (row) => ColoredBox(
                  color: Theme.of(context).appBarTheme.backgroundColor ??
                      context.palette.background,
                  child: row,
                ),
              ),
              body: MydiaInstanceBody(sourceId: sourceId),
            );
          },
        ),
      ),
    );
  }
}

/// One instance's settings without a `Scaffold`: the mobile screen and the
/// desktop settings dialog both host it.
class MydiaInstanceBody extends ConsumerWidget {
  const MydiaInstanceBody({
    super.key,
    required this.sourceId,
    this.padding = const EdgeInsets.all(16),
  });

  final SourceId sourceId;
  final EdgeInsets padding;

  Future<void> _remove(
    BuildContext context,
    WidgetRef ref,
    ProviderAccount account,
  ) async {
    final nav = SettingsNavScope.of(context);
    final toaster = Toaster.of(context);
    final l10n = context.l10n;
    try {
      final confirmed = await confirmRemoveAccount(
        context,
        ref,
        account,
        title: l10n.sourcesRemoveServerTitle,
        confirmLabel: l10n.sourcesRemoveServerConfirm,
      );
      if (!confirmed) return;
      await removeMydiaInstance(ref, account);
      nav.instanceRemoved();
    } catch (_) {
      toaster.show(l10n.sourcesInstanceRemoveFailed, kind: ToastKind.error);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account =
        mydiaAccountFor(ref.watch(sourceRecordsProvider).value, sourceId);
    return account == null
        ? Center(child: Text(context.l10n.sourcesInstanceMissing))
        : ListView(
            padding: padding,
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
                        label: context.l10n.commonRemove,
                        children: [
                          SettingsRow.action(
                            key: const Key('mydia-instance-remove'),
                            icon: Icons.logout,
                            title: context.l10n.sourcesInstanceRemoveRow,
                            subtitle:
                                context.l10n.sourcesInstanceRemoveRowSubtitle,
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
    final l10n = context.l10n;
    return SettingsSection(
      label: l10n.commonServer,
      children: [
        SettingsRow.action(
          icon: Icons.dns_rounded,
          title: account.displayName,
          subtitle: switch (address) {
            MydiaInstanceUrl(:final url) => url,
            MydiaInstanceP2p() => l10n.sourcesInstanceP2p,
            null => null,
          },
        ),
        SettingsRow.action(
          key: const Key('mydia-instance-version'),
          icon: Icons.info_outline,
          title: switch (compat) {
            AsyncData() => version == null
                ? l10n.sourcesInstanceVersionUnknown
                : 'v$version',
            _ => l10n.sourcesInstanceChecking,
          },
          subtitle: compat.value == null
              ? null
              : _verdictLabel(l10n, compat.value!.verdict),
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
      label: context.l10n.sourcesInstanceThisDevice,
      children: [
        SettingsRow.action(
          icon: Icons.settings_remote,
          title: context.l10n.registrationStatusText(status),
        ),
        if (status is RegistrationFailed)
          SettingsRow.action(
            key: const Key('mydia-instance-registration-retry'),
            icon: Icons.refresh,
            title: context.l10n.settingsRetryRegistrationTitle,
            subtitle: context.l10n.settingsRetryRegistrationSubtitle,
            onTap: () =>
                ref.read(nodeRegistrationsProvider.notifier).retry(sourceId),
          ),
      ],
    );
  }
}
