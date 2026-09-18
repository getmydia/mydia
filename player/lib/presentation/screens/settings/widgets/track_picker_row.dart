import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/theme/colors.dart';
import '../../../../core/update/update_provider.dart';
import '../../../../core/update/update_track.dart';

/// Lets the viewer choose which release cadence this installation follows.
///
/// One tappable option per track in [availableTracks], so a platform that has
/// never published a track (macOS has no dev builds, Flatpak has no dev
/// branch) simply never offers it rather than offering a choice that resolves
/// to nothing.
///
/// Selecting a lower track never downgrades anything: the installed build
/// stays until the chosen track publishes something newer. That is stated in
/// plain words below the options whenever [installedVersion] looks newer than
/// what [currentTrack] would offer, built entirely from the values passed in.
///
/// Built from the same primitives as `SettingsRow` (a plain `InkWell`, which
/// is already focusable and D-pad operable on its own) so the row inherits
/// their focus handling rather than inventing a new one, since this build
/// also ships to televisions.
class TrackPickerRow extends StatelessWidget {
  const TrackPickerRow({
    super.key,
    required this.availableTracks,
    required this.currentTrack,
    required this.installedVersion,
    this.deferredInstructions,
    this.deferredUrl,
    required this.onSelected,
  });

  /// The tracks worth offering. Rendered in [UpdateTrack.values] order,
  /// regardless of the set's own iteration order.
  final Set<UpdateTrack> availableTracks;

  /// The track this installation currently follows. Drawn selected.
  final UpdateTrack currentTrack;

  /// The version actually running, used to explain a wait without ever
  /// inventing a number of its own.
  final String installedVersion;

  /// Instructions handed back by a backend that could not make the switch
  /// itself (Flatpak's branch, TestFlight's group). Non-null means "show
  /// this instead of pretending the switch happened".
  final String? deferredInstructions;

  /// A link alongside [deferredInstructions], shown only when both are set.
  final String? deferredUrl;

  final Future<void> Function(UpdateTrack track) onSelected;

  @override
  Widget build(BuildContext context) {
    final tracks = UpdateTrack.values.where(availableTracks.contains).toList();
    final notice = _downgradeNotice();
    final instructions = deferredInstructions;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Release track',
            style: TextStyle(
              fontSize: 14.5,
              fontWeight: FontWeight.w500,
              letterSpacing: -0.1,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 10),
          for (final track in tracks)
            _TrackOption(
              track: track,
              selected: track == currentTrack,
              onTap: () => onSelected(track),
            ),
          if (notice != null) ...[
            const SizedBox(height: 10),
            Text(
              notice,
              style: const TextStyle(
                fontSize: 12.5,
                height: 1.4,
                color: AppColors.textSecondary,
              ),
            ),
          ],
          if (instructions != null) ...[
            const SizedBox(height: 12),
            _DeferredInstructions(
              instructions: instructions,
              url: deferredUrl,
            ),
          ],
        ],
      ),
    );
  }

  /// Explains, in the running build's own terms, why choosing [currentTrack]
  /// will not move anything backward.
  ///
  /// Triggers when [installedVersion]'s own suffix reads as a track ranked
  /// ahead of [currentTrack] (dev ahead of beta ahead of stable), which is
  /// the only signal this row has: it is never told what the chosen track
  /// last published, only what is actually installed.
  String? _downgradeNotice() {
    final implied = _impliedTrack(installedVersion);
    if (implied == null || implied.index <= currentTrack.index) return null;

    return 'You are on $installedVersion. ${currentTrack.label} will not '
        'install anything older, so you will stay on this build until '
        '${currentTrack.label} publishes one newer than it.';
  }

  /// The track whose naming convention [version] looks like it came from: no
  /// prerelease suffix reads as stable, `-beta.N` as beta, `-dev.N` or
  /// `-alpha.N` as dev. Null for anything else, so an unfamiliar shape never
  /// backs a claim this cannot support.
  static UpdateTrack? _impliedTrack(String version) {
    final hyphen = version.indexOf('-');
    if (hyphen == -1) return UpdateTrack.stable;

    final identifier = version.substring(hyphen + 1).split('.').first;
    final letters = RegExp(r'^[A-Za-z]+').stringMatch(identifier) ?? identifier;
    return switch (letters.toLowerCase()) {
      'beta' => UpdateTrack.beta,
      'dev' || 'alpha' => UpdateTrack.dev,
      _ => null,
    };
  }
}

/// One selectable track, styled after the check-marked rows the quality
/// picker already uses elsewhere in this app.
class _TrackOption extends StatelessWidget {
  const _TrackOption({
    required this.track,
    required this.selected,
    required this.onTap,
  });

  final UpdateTrack track;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      key: Key('update-track-option-${track.wireName}'),
      selected: selected,
      button: true,
      label: track.label,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  selected ? Icons.check_circle : Icons.circle_outlined,
                  size: 18,
                  color: selected ? AppColors.primary : AppColors.textDisabled,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        track.label,
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w500,
                          color: selected
                              ? AppColors.textPrimary
                              : AppColors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        track.description,
                        style: const TextStyle(
                          fontSize: 12,
                          height: 1.35,
                          color: AppColors.textDisabled,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The instructions a deferred switch handed back, plus its link when one was
/// given. Selectable because the block is often a shell command the viewer
/// needs to copy, not just read.
class _DeferredInstructions extends StatelessWidget {
  const _DeferredInstructions({required this.instructions, this.url});

  final String instructions;
  final String? url;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final link = url;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText(
            instructions,
            style: const TextStyle(
              fontSize: 12.5,
              height: 1.5,
              color: AppColors.textSecondary,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          if (link != null) ...[
            const SizedBox(height: 8),
            InkWell(
              onTap: () => _openLink(link),
              child: Text(
                link,
                style: TextStyle(
                  fontSize: 12.5,
                  color: scheme.primary,
                  decoration: TextDecoration.underline,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _openLink(String url) async {
    final uri = Uri.tryParse(url);
    if (uri != null) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }
}

/// The picker, wired to the update state.
///
/// Renders nothing when the backend offers no tracks, which is iOS, web, and
/// any Android copy installed from Play. That is why the call site needs no
/// platform check of its own, unlike the macOS-only row this replaced.
class UpdateTrackSection extends ConsumerWidget {
  const UpdateTrackSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(updateProvider);
    if (state.availableTracks.isEmpty) return const SizedBox.shrink();

    return TrackPickerRow(
      availableTracks: state.availableTracks,
      currentTrack: state.currentTrack,
      installedVersion: state.currentVersion,
      deferredInstructions: state.trackNotice,
      onSelected: (track) =>
          ref.read(updateProvider.notifier).selectTrack(track),
    );
  }
}
