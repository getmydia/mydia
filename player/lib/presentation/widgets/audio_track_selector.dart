import 'package:flutter/material.dart';

import '../../core/theme/palette.dart';
import '../../domain/models/audio_track.dart';
import '../../l10n/l10n.dart';
import 'osd_sheet.dart';

/// Shows a bottom sheet for selecting an audio track.
///
/// Returns the selected [AudioTrack], or null if cancelled.
Future<AudioTrack?> showAudioTrackSelector(
  BuildContext context,
  List<AudioTrack> tracks,
  AudioTrack? currentTrack,
) async {
  return showOsdBottomSheet<AudioTrack?>(
    context: context,
    builder: (context) => AudioTrackSelectorSheet(
      tracks: tracks,
      currentTrack: currentTrack,
    ),
  );
}

/// Bottom sheet widget for audio track selection.
class AudioTrackSelectorSheet extends StatelessWidget {
  final List<AudioTrack> tracks;
  final AudioTrack? currentTrack;

  const AudioTrackSelectorSheet({
    super.key,
    required this.tracks,
    this.currentTrack,
  });

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Material(
      type: MaterialType.transparency,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                context.l10n.audioTracksTitle,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      color: palette.textPrimary,
                      fontWeight: FontWeight.bold,
                    ),
              ),
            ),
            const SizedBox(height: 16),
            if (tracks.isEmpty)
              Padding(
                padding: const EdgeInsets.all(20),
                child: Text(
                  context.l10n.audioTracksEmpty,
                  style: TextStyle(color: palette.textSecondary),
                ),
              )
            else
              ...tracks.map(
                (track) => _TrackTile(
                  title: context.l10n.audioTrackName(track),
                  isDefault: track.isDefault,
                  isSelected: currentTrack?.id == track.id,
                  onTap: () => Navigator.of(context).pop(track),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Individual track selection tile.
class _TrackTile extends StatelessWidget {
  final String title;
  final bool isDefault;
  final bool isSelected;
  final VoidCallback onTap;

  const _TrackTile({
    required this.title,
    required this.isDefault,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return ListTile(
      title: Text(
        title,
        style: TextStyle(
          color: palette.textPrimary,
          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
        ),
      ),
      subtitle: isDefault
          ? Text(
              context.l10n.commonDefault,
              style: TextStyle(color: palette.textSecondary),
            )
          : null,
      trailing: isSelected ? Icon(Icons.check, color: palette.primary) : null,
      onTap: onTap,
    );
  }
}
