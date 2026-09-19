import 'package:flutter/material.dart';

import '../../core/theme/colors.dart';
import '../../domain/models/audio_track.dart';
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
                'Audio Tracks',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.bold,
                    ),
              ),
            ),
            const SizedBox(height: 16),
            if (tracks.isEmpty)
              const Padding(
                padding: EdgeInsets.all(20),
                child: Text(
                  'No audio tracks available',
                  style: TextStyle(color: AppColors.textSecondary),
                ),
              )
            else
              ...tracks.map(
                (track) => _TrackTile(
                  title: track.displayName,
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
    return ListTile(
      title: Text(
        title,
        style: TextStyle(
          color: AppColors.textPrimary,
          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
        ),
      ),
      subtitle: isDefault
          ? const Text(
              'Default',
              style: TextStyle(color: AppColors.textSecondary),
            )
          : null,
      trailing:
          isSelected ? const Icon(Icons.check, color: AppColors.primary) : null,
      onTap: onTap,
    );
  }
}
