import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/player/input_capabilities.dart';
import '../../core/update/install_environment.dart';
import '../../core/update/update_provider.dart';
import '../../domain/models/available_update.dart';
import '../../l10n/l10n.dart';
import 'glass/glass_dialog.dart';

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
///
/// On a directional-primary device (Android TV) the `inPlace` branch skips
/// the confirmation: Android's package installer opens its own confirm
/// screen, which is the confirmation, and a second dialog is one more
/// remote press for nothing. [directionalPrimary] defaults to
/// [InputCapabilities.directionalPrimary] and exists so tests can choose.
///
/// Flatpak used to show a dialog naming `flatpak update <app id>` for the
/// user to run themselves. `UpdateBackend` now knows how to update a Flatpak
/// install in place through `org.freedesktop.portal.Flatpak`, so that branch
/// asks the backend to do the work instead of telling the user to open a
/// terminal. It skips the confirmation `inPlace` shows, matching the
/// Settings "Check for updates" row, which already checks and installs a
/// Flatpak update in one step with no confirmation of its own.
Future<void> startUpdate(
  BuildContext context,
  WidgetRef ref, {
  InstallEnvironment? environmentOverride,
  UrlLauncher? launcher,
  bool? directionalPrimary,
}) async {
  final update = ref.read(updateProvider).availableUpdate;
  if (update == null) return;

  final environment = environmentOverride ?? InstallEnvironment.detect();

  switch (environment) {
    case InstallEnvironment.flatpak:
      unawaited(ref.read(updateProvider.notifier).requestUpdate());

    case InstallEnvironment.readOnly:
      // Guards a mismatch between environment and update type that should
      // never happen in practice: a Flatpak host only ever produces a
      // FlatpakRemoteUpdate, handled above, and every other host only ever
      // produces an AppUpdate.
      if (update is AppUpdate) {
        await _openReleasePage(update, launcher ?? _launch);
      }

    case InstallEnvironment.inPlace:
      final notifier = ref.read(updateProvider.notifier);
      // A backend that cannot update in place has nothing to confirm; asking
      // it anyway is how it explains itself (UpdateUnsupported). The Settings
      // card always did this, so one shared path keeps it.
      if (!notifier.canUpdateInPlace) {
        unawaited(notifier.requestUpdate());
        return;
      }
      if (update is! AppUpdate) return;
      if (directionalPrimary ?? InputCapabilities.directionalPrimary) {
        unawaited(notifier.requestUpdate());
        return;
      }
      final confirmed = await _confirmInPlace(context, update);
      // The dialog awaited a person, so the widget that started this can be
      // gone by the time it returns.
      if (!confirmed || !context.mounted) return;
      unawaited(notifier.requestUpdate());
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
    builder: (ctx) => GlassDialog(
      title: Text(ctx.l10n.updateConfirmTitle),
      content: Text(ctx.l10n.updateConfirmBody(update.version)),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(ctx.l10n.commonCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(ctx.l10n.commonUpdate),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}
