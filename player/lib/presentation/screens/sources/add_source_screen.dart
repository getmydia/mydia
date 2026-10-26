library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/sources/lock/source_lock_controller.dart';
import '../../../core/sources/sources_providers.dart';
import '../../../l10n/l10n.dart';

class AddSourceScreen extends ConsumerWidget {
  const AddSourceScreen({super.key, this.isWeb = kIsWeb});

  /// Third-party sources do not exist on web, so a second Mydia added there
  /// would vanish. Overridable for tests.
  final bool isWeb;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasMydia = ref.watch(hasMydiaProvider);
    final guestsUnavailable = hasMydia && isWeb;
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.sourcesAddTitle)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: ListView(
            padding: const EdgeInsets.all(24),
            shrinkWrap: true,
            children: [
              ListTile(
                key: const Key('add-source-plex'),
                autofocus: true,
                leading: const Icon(Icons.live_tv_rounded),
                title: const Text('Plex'), // l10n-ignore: product name
                subtitle: Text(context.l10n.sourcesAddPlexSubtitle),
                onTap: () => context.push('/sources/add/plex'),
              ),
              ListTile(
                key: const Key('add-source-jellyfin'),
                leading: const Icon(Icons.smart_display_rounded),
                title: const Text('Jellyfin'), // l10n-ignore: product name
                subtitle: Text(context.l10n.sourcesAddJellyfinSubtitle),
                onTap: () => context.push('/sources/add/jellyfin'),
              ),
              ListTile(
                key: const Key('add-source-stash'),
                leading: const Icon(Icons.video_library_rounded),
                title: const Text('Stash'), // l10n-ignore: product name
                subtitle: Text(context.l10n.sourcesAddStashSubtitle),
                onTap: () => context.push('/sources/add/stash'),
              ),
              ListTile(
                key: const Key('add-source-mydia'),
                leading: const Icon(Icons.dns_rounded),
                title: const Text('Mydia'), // l10n-ignore: product name
                enabled: !guestsUnavailable,
                subtitle: Text(switch ((hasMydia, guestsUnavailable)) {
                  (true, true) => context.l10n.sourcesAddMydiaOnlyInApps,
                  (true, false) => context.l10n.sourcesAddMydiaShared,
                  _ => context.l10n.sourcesAddMydiaSignIn,
                }),
                onTap: () => context.push('/sources/add/mydia'),
              ),
            ],
          ),
        ),
      ),
    );
  }
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
