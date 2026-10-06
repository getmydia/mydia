library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/player/input_capabilities.dart';
import '../../../core/sources/plex/plex_tv_client.dart';
import '../detail/detail_links.dart';
import 'plex_sign_in_controller.dart';

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
            Text('Go to plex.tv/link and enter this code',
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
                label: const Text('Open plex.tv/link'),
              ),
            const SizedBox(height: 24),
            const SizedBox(width: 200, child: LinearProgressIndicator()),
            const SizedBox(height: 8),
            Text('Waiting for approval', style: theme.textTheme.bodySmall),
          ],
        ),
      PlexSignInChoosing(:final servers, :final chosen) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Choose servers to add', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            for (final (i, server) in servers.indexed)
              CheckboxListTile(
                key: Key('plex-server-${server.clientIdentifier}'),
                autofocus: i == 0,
                value: chosen.contains(server.clientIdentifier),
                onChanged: (_) => controller.toggle(server.clientIdentifier),
                title: Text(server.name),
                subtitle: Text([
                  server.owned ? 'Yours' : 'Shared with you',
                  if (!server.presence) 'Offline',
                ].join(' · ')),
              ),
            const SizedBox(height: 16),
            FilledButton(
              key: const Key('plex-add-servers'),
              onPressed: chosen.isEmpty ? null : controller.save,
              child: Text(chosen.length == 1
                  ? 'Add 1 server'
                  : 'Add ${chosen.length} servers'),
            ),
          ],
        ),
      PlexSignInFailed(:final message) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(
              key: const Key('plex-try-again'),
              autofocus: true,
              onPressed: controller.start,
              child: const Text('Try again'),
            ),
          ],
        ),
    };

    return Scaffold(
      appBar: AppBar(title: const Text('Sign in to Plex')),
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
