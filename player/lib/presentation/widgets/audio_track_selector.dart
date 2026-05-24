import 'package:flutter/material.dart';
import '../../domain/models/audio_track.dart';

/// Shows a bottom sheet for selecting an audio track.
///
/// Returns the selected [AudioTrack], or null if cancelled.
Future<AudioTrack?> showAudioTrackSelector(
  BuildContext context,
  List<AudioTrack> tracks,
  AudioTrack? currentTrack,
) async {
  return showModalBottomSheet<AudioTrack?>(
    context: context,
    backgroundColor: Colors.grey[900],
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
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
    return Container(
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
                    color: Colors.white,
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
                style: TextStyle(color: Colors.grey),
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
          color: Colors.white,
          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
        ),
      ),
      subtitle: isDefault
          ? const Text(
              'Default',
              style: TextStyle(color: Colors.grey),
            )
          : null,
      trailing: isSelected ? const Icon(Icons.check, color: Colors.red) : null,
      onTap: onTap,
    );
  }
}
