import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/theme/palette.dart';
import '../../../../core/update/install_environment.dart';
import '../../../../core/update/update_provider.dart';
import '../../../../domain/models/available_update.dart';
import '../../../../l10n/l10n.dart';
import 'settings_section.dart';
import '../../../widgets/update_action.dart';

/// The available-update card, shown above the settings sections.
///
/// It renders nothing unless there is something to say. The platform gate it
/// used to carry moved into createUpdateBackend, which returns null on
/// platforms that update through a store, so a dead card is unrepresentable
/// rather than merely guarded against.
class UpdateCard extends ConsumerWidget {
  /// Forwarded to [startUpdate], so a test is not at the mercy of whichever
  /// install environment the host running it happens to be.
  @visibleForTesting
  final InstallEnvironment? environmentOverride;

  const UpdateCard({super.key, this.environmentOverride});

  /// The Material focus overlay is a faint tint that all but disappears on the
  /// dark palette, which leaves a D-pad user unsure which button is selected.
  /// An outline on focus matches the ring [FocusHighlight] draws elsewhere.
  static final ButtonStyle _focusRing = ButtonStyle(
    side: WidgetStateBorderSide.resolveWith(
      (states) => states.contains(WidgetState.focused)
          ? const BorderSide(color: Colors.white, width: 2)
          : null,
    ),
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = context.palette;
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
      final message = state.notice ?? context.l10n.updateErrorMessage(state);
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
                  color: state.hasError
                      ? Theme.of(context).colorScheme.error
                      : palette.textSecondary,
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
                  _heading(
                    context.l10n,
                    update: update,
                    awaitingRestart: awaitingRestart,
                  ),
                  style: TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                    color: palette.textPrimary,
                  ),
                ),
                if (update is AppUpdate) ...[
                  const SizedBox(height: 2),
                  Text(
                    update.releaseTitle,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: palette.textSecondary,
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
                    style: _focusRing,
                    icon: const Icon(Icons.restart_alt, size: 18),
                    label: Text(context.l10n.settingsUpdateRestart),
                  )
                else if (update != null)
                  Row(
                    children: [
                      FilledButton.icon(
                        onPressed: () => startUpdate(
                          context,
                          ref,
                          environmentOverride: environmentOverride,
                        ),
                        style: _focusRing,
                        icon: const Icon(Icons.download, size: 18),
                        label: Text(context.l10n.settingsUpdateNow),
                      ),
                      const SizedBox(width: 8),
                      TextButton(
                        style: _focusRing,
                        onPressed: () =>
                            _openReleaseNotes(update.releaseNotesUrl),
                        child: Text(context.l10n.settingsUpdateReleaseNotes),
                      ),
                    ],
                  ),
                if (state.hasError) ...[
                  const SizedBox(height: 8),
                  Text(
                    context.l10n.updateErrorMessage(state) ?? '',
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
  String _heading(
    AppLocalizations l10n, {
    required AvailableUpdate? update,
    required bool awaitingRestart,
  }) {
    if (awaitingRestart) return l10n.settingsUpdateRestartToFinish;
    final version = update?.version;
    if (version != null) return l10n.settingsUpdateAvailableVersion(version);
    if (update != null) return l10n.settingsUpdateAvailableNoVersion;
    return l10n.settingsUpdatesSection;
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
              ? context.l10n
                  .settingsUpdateDownloadingPercent((progress * 100).toInt())
              : context.l10n.settingsUpdateDownloading,
          style: TextStyle(
            fontSize: 12,
            color: context.palette.textSecondary,
          ),
        ),
      ],
    );
  }
}
