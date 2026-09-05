import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/update/install_environment.dart';
import '../../core/update/update_provider.dart';
import '../../domain/models/app_update.dart';

/// The Flatpak application id, matching `player/flatpak/dev.mydia.player.yml`.
const String flatpakAppId = 'dev.mydia.player';

/// Opens a URL. Injectable so tests can observe the read-only branch without
/// a url_launcher platform implementation.
typedef UrlLauncher = Future<void> Function(Uri uri);

/// Begins an update, however this install is able to take one.
///
/// The single implementation, called by `UpdateBanner`, `UpdateCard` and
/// `CompatibilityBanner`. `CompatibilityBanner` used to route to Settings to
/// avoid a second place that could get the GitHub-versus-app-store question
/// wrong; one shared action answers that objection instead of working around
/// it.
Future<void> startUpdate(
  BuildContext context,
  WidgetRef ref, {
  InstallEnvironment? environmentOverride,
  UrlLauncher? launcher,
}) async {
  final update = ref.read(updateProvider).availableUpdate;
  if (update == null) return;

  final environment = environmentOverride ?? InstallEnvironment.detect();

  switch (environment) {
    case InstallEnvironment.flatpak:
      await _showFlatpakDialog(context, update);

    case InstallEnvironment.readOnly:
      await _openReleasePage(update, launcher ?? _launch);

    case InstallEnvironment.inPlace:
      final confirmed = await _confirmInPlace(context, update);
      // The dialog awaited a person, so the widget that started this can be
      // gone by the time it returns.
      if (!confirmed || !context.mounted) return;
      unawaited(ref.read(updateProvider.notifier).applyUpdate());
  }
}

Future<void> _launch(Uri uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);

Future<void> _openReleasePage(AppUpdate update, UrlLauncher launcher) async {
  final uri = Uri.tryParse(update.releaseNotesUrl);
  if (uri == null) return;
  await launcher(uri);
}

Future<bool> _confirmInPlace(BuildContext context, AppUpdate update) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Update Mydia'),
      content: Text(
        'Mydia will close and update to v${update.version}. Continue?',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('Update'),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}

Future<void> _showFlatpakDialog(BuildContext context, AppUpdate update) {
  const command = 'flatpak update $flatpakAppId';

  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Update to v${update.version}'),
      content: const Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Mydia is installed as a Flatpak, so it updates through Flatpak '
            'rather than replacing itself. Run:',
          ),
          SizedBox(height: 12),
          SelectableText(
            command,
            style: TextStyle(fontFamily: 'monospace', fontSize: 13),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () async {
            await Clipboard.setData(const ClipboardData(text: command));
            if (ctx.mounted) Navigator.of(ctx).pop();
          },
          child: const Text('Copy command'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}
