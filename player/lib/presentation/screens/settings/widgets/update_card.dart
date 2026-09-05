import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/theme/colors.dart';
import '../../../../core/update/update_provider.dart';
import '../../../../domain/models/available_update.dart';
import 'settings_section.dart';

/// The available-update card, shown above the settings sections.
///
/// It renders nothing unless there is something to say. The platform gate it
/// used to carry moved into createUpdateBackend, which returns null on
/// platforms that update through a store, so a dead card is unrepresentable
/// rather than merely guarded against.
class UpdateCard extends ConsumerWidget {
  const UpdateCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(updateProvider);
    final update = state.availableUpdate;

    final awaitingRestart = state.restartRequired ||
        (update is FlatpakRemoteUpdate && update.installedAwaitingRestart);

    if (update == null && !awaitingRestart) {
      // Either a notice (confirming there was nothing to install) or an
      // error. An error belongs here too: a check that fails before any
      // update was ever held, such as a Flatpak whose portal is
      // unreachable, never populates availableUpdate, so state.error is the
      // only signal that anything happened at all. Without it here the row
      // presses, waits, and reports nothing, which reads as the check doing
      // nothing rather than failing.
      final message = state.notice ?? state.error;
      if (message == null) {
        return const SizedBox.shrink();
      }

      // One line, no actions, either way.
      return Padding(
        padding: const EdgeInsets.only(bottom: 18),
        child: SettingsCard(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                message,
                style: TextStyle(
                  fontSize: 13,
                  color: state.error != null
                      ? Theme.of(context).colorScheme.error
                      : AppColors.textSecondary,
                ),
              ),
            ),
          ],
        ),
      );
    }

    // The card owns the space below it rather than the screen owning the space
    // above it. Both early returns above contribute nothing, so the screen
    // needs no spacer either way and an available update cannot butt up against
    // the section that follows.
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: SettingsCard(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _heading(update: update, awaitingRestart: awaitingRestart),
                  style: const TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
                if (update is AppUpdate) ...[
                  const SizedBox(height: 2),
                  Text(
                    update.releaseTitle,
                    style: const TextStyle(
                      fontSize: 12.5,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
                const SizedBox(height: 14),
                if (state.isApplying)
                  _Progress(progress: state.downloadProgress)
                else if (awaitingRestart)
                  FilledButton.icon(
                    onPressed: () =>
                        ref.read(updateProvider.notifier).restart(),
                    icon: const Icon(Icons.restart_alt, size: 18),
                    label: const Text('Restart'),
                  )
                else if (update != null)
                  Row(
                    children: [
                      FilledButton.icon(
                        onPressed: () => _handleUpdateTap(context, ref),
                        icon: const Icon(Icons.download, size: 18),
                        label: const Text('Update Now'),
                      ),
                      const SizedBox(width: 8),
                      TextButton(
                        onPressed: () =>
                            _openReleaseNotes(update.releaseNotesUrl),
                        child: const Text('Release Notes'),
                      ),
                    ],
                  ),
                if (state.error != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    state.error!,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The one line at the top. A Flatpak update cannot name a version, because
  /// the portal reports commits, so it says so plainly rather than inventing
  /// one.
  String _heading({
    required AvailableUpdate? update,
    required bool awaitingRestart,
  }) {
    if (awaitingRestart) return 'Restart to finish updating';
    final version = update?.version;
    if (version != null) return 'Update available: v$version';
    if (update != null) return 'A new version of Mydia Player is available';
    return 'Updates';
  }

  void _handleUpdateTap(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(updateProvider.notifier);

    if (!notifier.canUpdateInPlace) {
      notifier.requestUpdate();
      return;
    }

    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Update Mydia'),
        content: const Text(
          'Mydia will download and install the newest build, then offer to '
          'restart. Continue?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              notifier.requestUpdate();
            },
            child: const Text('Update'),
          ),
        ],
      ),
    );
  }

  Future<void> _openReleaseNotes(String url) async {
    final uri = Uri.tryParse(url);
    if (uri != null) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }
}

/// The download bar and its label.
///
/// At zero the bar is indeterminate, so a "0%" label would claim a precision
/// the bar itself is not showing.
class _Progress extends StatelessWidget {
  const _Progress({required this.progress});

  final double progress;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LinearProgressIndicator(value: progress > 0 ? progress : null),
        const SizedBox(height: 6),
        Text(
          progress > 0
              ? 'Downloading ${(progress * 100).toInt()}%'
              : 'Downloading',
          style: const TextStyle(
            fontSize: 12,
            color: AppColors.textSecondary,
          ),
        ),
      ],
    );
  }
}
