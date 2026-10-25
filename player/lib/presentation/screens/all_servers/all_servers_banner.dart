/// Names the servers a merged view could not include, with Retry, and the
/// included ones that need signing in again.
library;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/sources/source.dart';
import '../../../core/sources/sources_providers.dart';
import '../../../l10n/l10n.dart';
import '../settings/dialog/open_settings.dart';
import '../settings/dialog/settings_dialog.dart';

class AllServersBanner extends ConsumerStatefulWidget {
  const AllServersBanner(
      {super.key, required this.unavailable, required this.onRetry});

  final List<SourceId> unavailable;
  final VoidCallback onRetry;

  @override
  ConsumerState<AllServersBanner> createState() => _AllServersBannerState();
}

class _AllServersBannerState extends ConsumerState<AllServersBanner> {
  bool _dismissed = false;

  @override
  void didUpdateWidget(AllServersBanner old) {
    super.didUpdateWidget(old);
    if (!listEquals(old.unavailable, widget.unavailable)) _dismissed = false;
  }

  @override
  Widget build(BuildContext context) {
    final sources = ref.watch(sourcesProvider);
    String name(SourceId id) =>
        sources.where((s) => s.id == id).firstOrNull?.displayName ?? id.value;
    // A result can outlive a server leaving the set (relocked, switched off);
    // only servers still included are named.
    final included = {
      for (final s in ref.watch(allServersSourcesProvider)) s.id
    };
    final unavailable = widget.unavailable.where(included.contains).toList();
    final signIn = ref.watch(allServersNeedSignInProvider);
    final theme = Theme.of(context);
    return Column(children: [
      if (unavailable.isNotEmpty && !_dismissed)
        MaterialBanner(
          key: const Key('all-unavailable-banner'),
          content: Text(context.l10n
              .allServersUnavailable(unavailable.map(name).join(', '))),
          actions: [
            TextButton(
                key: const Key('all-unavailable-retry'),
                onPressed: widget.onRetry,
                child: Text(context.l10n.commonRetry)),
            IconButton(
                key: const Key('all-unavailable-dismiss'),
                tooltip: context.l10n.commonDismiss,
                onPressed: () => setState(() => _dismissed = true),
                icon: const Icon(Icons.close)),
          ],
        ),
      if (signIn.isNotEmpty)
        ListTile(
          key: const Key('all-needs-sign-in'),
          leading: Icon(Icons.lock_outline, color: theme.colorScheme.error),
          title: Text(context.l10n.allServersNeedSignIn(
              signIn.map((s) => s.displayName).join(', '))),
          trailing: TextButton(
              onPressed: () =>
                  openSettings(context, initial: SettingsCategory.servers),
              child: Text(context.l10n.navManageServers)),
        ),
    ]);
  }
}
