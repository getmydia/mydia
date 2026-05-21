import 'package:flutter/material.dart';
import '../../domain/models/subtitle_track.dart';

/// Shows a bottom sheet for selecting a subtitle track.
///
/// Returns the selected [SubtitleTrack], or null if "Off" is selected.
Future<SubtitleTrack?> showSubtitleTrackSelector(
  BuildContext context,
  List<SubtitleTrack> tracks,
  SubtitleTrack? currentTrack,
) async {
  return showModalBottomSheet<SubtitleTrack?>(
    context: context,
    backgroundColor: Colors.grey[900],
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (context) => SubtitleTrackSelectorSheet(
      tracks: tracks,
      currentTrack: currentTrack,
    ),
  );
}

/// Bottom sheet widget for subtitle track selection.
class SubtitleTrackSelectorSheet extends StatelessWidget {
  final List<SubtitleTrack> tracks;
  final SubtitleTrack? currentTrack;

  const SubtitleTrackSelectorSheet({
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
              'Subtitles',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
            ),
          ),
          const SizedBox(height: 16),
          // "Off" option
          _TrackTile(
            title: 'Off',
            isSelected: currentTrack == null,
            onTap: () => Navigator.of(context).pop(null),
          ),
          const Divider(color: Colors.grey, height: 1),
          // Available tracks
          if (tracks.isEmpty)
            const Padding(
              padding: EdgeInsets.all(20),
              child: Text(
                'No subtitle tracks available',
                style: TextStyle(color: Colors.grey),
              ),
            )
          else
            ...tracks.map(
              (track) => _TrackTile(
                title: track.displayName,
                subtitle: track.embedded ? 'Embedded' : 'External',
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
  final String? subtitle;
  final bool isSelected;
  final VoidCallback onTap;

  const _TrackTile({
    required this.title,
    this.subtitle,
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
      subtitle: subtitle != null
          ? Text(
              subtitle!,
              style: const TextStyle(color: Colors.grey),
            )
          : null,
      trailing: isSelected ? const Icon(Icons.check, color: Colors.red) : null,
      onTap: onTap,
    );
  }
}
