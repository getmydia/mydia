library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/player/input_capabilities.dart';
import '../../../core/sources/plex/plex_tv_client.dart';
import '../../../l10n/l10n.dart';
import '../detail/detail_links.dart';
import 'plex_sign_in_controller.dart';
import 'sign_in_problem.dart';

class PlexSignInScreen extends ConsumerStatefulWidget {
  const PlexSignInScreen({super.key, this.reauthAccountId});

  final String? reauthAccountId;

  @override
  ConsumerState<PlexSignInScreen> createState() => _PlexSignInScreenState();
}

class _PlexSignInScreenState extends ConsumerState<PlexSignInScreen> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() =>
        ref.read(plexSignInProvider(widget.reauthAccountId).notifier).start());
  }

  @override
  Widget build(BuildContext context) {
    final provider = plexSignInProvider(widget.reauthAccountId);
    ref.listen(provider, (_, next) {
      if (next is PlexSignInDone) {
        final first = next.firstSource;
        context.go(first == null ? '/' : sourceHomeLocation(first));
      }
    });
    final state = ref.watch(provider);
    final controller = ref.read(provider.notifier);
    final theme = Theme.of(context);

    final Widget body = switch (state) {
      PlexSignInStarting() ||
      PlexSignInSaving() ||
      PlexSignInDone() =>
        const CircularProgressIndicator(),
      PlexSignInWaiting(:final code) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(context.l10n.sourcesPlexLinkPrompt,
                style: theme.textTheme.titleMedium),
            const SizedBox(height: 16),
            SelectableText(
              code,
              key: const Key('plex-pin-code'),
              style: theme.textTheme.displayMedium
                  ?.copyWith(letterSpacing: 8, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            if (!InputCapabilities.directionalPrimary)
              FilledButton.icon(
                key: const Key('plex-open-link'),
                autofocus: true,
                onPressed: () => launchUrl(Uri.parse(PlexTvClient.linkUrl),
                    mode: LaunchMode.externalApplication),
                icon: const Icon(Icons.open_in_new),
                label: Text(context.l10n.sourcesPlexOpenLink),
              ),
            const SizedBox(height: 24),
            const SizedBox(width: 200, child: LinearProgressIndicator()),
            const SizedBox(height: 8),
            Text(context.l10n.sourcesPlexWaiting,
                style: theme.textTheme.bodySmall),
          ],
        ),
      PlexSignInChoosing(:final servers, :final chosen) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(context.l10n.sourcesPlexChooseServers,
                style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            for (final (i, server) in servers.indexed)
              CheckboxListTile(
                key: Key('plex-server-${server.clientIdentifier}'),
                autofocus: i == 0,
                value: chosen.contains(server.clientIdentifier),
                onChanged: (_) => controller.toggle(server.clientIdentifier),
                title: Text(server.name),
                subtitle: Text([
                  server.owned
                      ? context.l10n.sourcesPlexOwned
                      : context.l10n.sourcesPlexShared,
                  if (!server.presence) context.l10n.commonOffline,
                ].join(' · ')),
              ),
            const SizedBox(height: 16),
            FilledButton(
              key: const Key('plex-add-servers'),
              onPressed: chosen.isEmpty ? null : controller.save,
              child: Text(context.l10n.sourcesPlexAddServers(chosen.length)),
            ),
          ],
        ),
      PlexSignInFailed(:final problem) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(context.l10n.signInProblemText(problem),
                textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(
              key: const Key('plex-try-again'),
              autofocus: true,
              onPressed: controller.start,
              child: Text(context.l10n.commonTryAgain),
            ),
          ],
        ),
    };

    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.sourcesPlexSignInTitle)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: body,
          ),
        ),
      ),
    );
  }
}
