library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/sources/lock/source_lock_controller.dart';
import '../../../core/sources/source.dart' show SourceLock;
import '../../../core/sources/store/source_records.dart';
import '../../../core/sources/sources_providers.dart';
import '../../../l10n/l10n.dart';
import '../connections/account_detail_page.dart';
import '../settings/settings_nav.dart';
import '../settings/widgets/settings_row.dart';
import '../settings/widgets/settings_section.dart';
import 'source_lock_sheet.dart';

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
              Card(
                key: ValueKey(record.account.id),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: AccountControls(record: record, unlocked: unlocked),
                ),
              ),
            const ShowHiddenSourcesRow(),
          ],
        ),
      AsyncError() => Center(child: Text(context.l10n.sourcesLoadFailed)),
      _ => const Center(child: CircularProgressIndicator()),
    };
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
