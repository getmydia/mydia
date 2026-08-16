import 'package:flutter/material.dart';

import '../../domain/models/cast_device.dart';

/// What the cast caption sheet resolved to when it closed.
///
/// Three outcomes rather than a nullable track, for the same reason
/// `SubtitleTrackSelection` has three (see
/// `subtitle_track_selector.dart`): `showModalBottomSheet` resolves to
/// `null` on a barrier tap or a back gesture, which makes a dismissal
/// indistinguishable from choosing "Off". Turning subtitles off is a
/// command to the receiver; backing out of the sheet must leave it alone.
sealed class CastSubtitleSelection {
  const CastSubtitleSelection();
}

/// The viewer picked a track already offered to the receiver.
///
/// [track] is always one of the instances passed into
/// [showCastSubtitleSheet]'s `tracks`, never rebuilt from an id: dart_cast
/// keys its internal Chromecast track ids by URL, and a re-derived URL that
/// differs by so much as a token falls back to activating trackId=1 with
/// only a log warning.
final class CastSubtitlePicked extends CastSubtitleSelection {
  final CastSubtitleTrack track;
  const CastSubtitlePicked(this.track);
}

/// The viewer picked "Off".
final class CastSubtitleOff extends CastSubtitleSelection {
  const CastSubtitleOff();
}

/// The sheet closed with no choice made: a barrier tap or a back gesture.
final class CastSubtitleCancelled extends CastSubtitleSelection {
  const CastSubtitleCancelled();
}

/// Shows the caption picker for a live cast session.
///
/// Never resolves to a bare `null`: see [CastSubtitleSelection] for why a
/// dismissal is reported distinctly from choosing "Off".
Future<CastSubtitleSelection> showCastSubtitleSheet(
  BuildContext context, {
  required List<CastSubtitleTrack> tracks,
  required CastSubtitleTrack? selected,
}) async {
  final result = await showModalBottomSheet<CastSubtitleSelection>(
    context: context,
    builder: (context) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          ListTile(
            key: const Key('cast-subtitle-off'),
            leading: const Icon(Icons.closed_caption_off),
            title: const Text('Off'),
            trailing: selected == null ? const Icon(Icons.check) : null,
            onTap: () => Navigator.of(context).pop(const CastSubtitleOff()),
          ),
          for (final track in tracks)
            ListTile(
              key: Key('cast-subtitle-track-${track.trackId}'),
              leading: const Icon(Icons.closed_caption),
              title: Text(track.label),
              subtitle: Text(track.language),
              trailing: selected?.trackId == track.trackId
                  ? const Icon(Icons.check)
                  : null,
              onTap: () => Navigator.of(context).pop(CastSubtitlePicked(track)),
            ),
        ],
      ),
    ),
  );

  return result ?? const CastSubtitleCancelled();
}
