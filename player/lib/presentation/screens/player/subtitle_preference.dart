/// The subtitle a viewer wants for this show, and how to find it on a file.
///
/// A subtitle track id is an ffprobe stream index, a sidecar UUID, or this
/// player's own synthetic `mk_<n>`, none of which survive to the next
/// episode. The server therefore remembers a descriptor, and this is where a
/// descriptor becomes a track on whatever list is actually on screen.
///
/// Deliberately separate from `subtitle_track_builder.dart`, which reconciles
/// two track lists and carries a choice across a source switch. Those are a
/// different problem, and keeping this file free of the player lets it be
/// tested without one.
library;

import '../../../core/language/language_equivalents.dart';
import '../../../domain/models/subtitle_track.dart';

export '../../../core/language/language_equivalents.dart'
    show subtitlePreferenceLanguageEquals;

/// What the server says should be showing, or null for "no opinion".
sealed class SubtitlePreference {
  const SubtitlePreference();
}

/// The viewer turned subtitles off for this show. Distinct from no
/// preference at all: this one has to beat mpv's own default-disposition
/// pick, which is what switches a subtitle on unasked in direct play.
final class PreferOff extends SubtitlePreference {
  const PreferOff();
}

/// The viewer wants a track matching this descriptor.
final class PreferTrack extends SubtitlePreference {
  const PreferTrack({
    required this.language,
    this.forced = false,
    this.hearingImpaired = false,
    this.trackTitle,
  });

  final String language;
  final bool forced;
  final bool hearingImpaired;

  /// The title of the track originally picked. A tiebreak only, never a
  /// requirement: two tracks can share a language and both flags, and a
  /// release names them consistently across a season.
  final String? trackTitle;
}

/// Reads the server's `preferredSubtitle` into a preference.
///
/// Returns null for a missing field and for a TRACK with no language, which
/// is a descriptor that could never match anything.
SubtitlePreference? subtitlePreferenceFrom({
  required String? mode,
  String? language,
  bool? forced,
  bool? hearingImpaired,
  String? trackTitle,
}) {
  switch (mode?.toUpperCase()) {
    case 'OFF':
      return const PreferOff();
    case 'TRACK':
      if (language == null || language.trim().isEmpty) return null;
      return PreferTrack(
        language: language,
        forced: forced ?? false,
        hearingImpaired: hearingImpaired ?? false,
        trackTitle: trackTitle,
      );
    default:
      return null;
  }
}

/// The best track on [tracks] for [pref], or null when none carries the
/// language.
///
/// Ranked rather than filtered, because a partial match is usually the right
/// answer: a season whose files disagree about SDH tagging should still keep
/// showing the viewer's language.
SubtitleTrack? matchSubtitlePreference(
  PreferTrack pref,
  List<SubtitleTrack> tracks,
) {
  final candidates = tracks
      .where((t) => subtitlePreferenceLanguageEquals(t.language, pref.language))
      .toList();
  if (candidates.isEmpty) return null;

  int score(SubtitleTrack t) {
    var value = 0;
    // Forced is the most consequential flag: a forced track subtitles only
    // foreign dialogue, so getting it wrong means either no subtitles on most
    // of the episode, or subtitles over a language the viewer already reads.
    if (t.forced == pref.forced) value += 8;
    if (t.hearingImpaired == pref.hearingImpaired) value += 4;
    final title = pref.trackTitle;
    if (title != null && title.isNotEmpty && t.title == title) value += 2;
    // Only as a last separator, so an unflagged list still resolves to the
    // full-dialogue track rather than the signs-only one.
    if (!t.forced) value += 1;
    return value;
  }

  candidates.sort((a, b) => score(b).compareTo(score(a)));
  return candidates.first;
}

/// Whether the stored preference may be applied to the playback right now.
///
/// Every input blocks for its own reason, and the check has to be all of them
/// together:
///
///  - [viewerChose]: they have already picked this playback, and re-applying
///    a stored preference over that would undo a deliberate choice.
///  - [switchInFlight]: a quality switch is about to replace the file, and it
///    carries the current choice across itself.
///  - [intentPending]: a carried choice is still waiting to be restored, and
///    it is newer than anything stored.
///  - [alreadyApplied]: media_kit revises its track list several times per
///    playback, and each revision reaches this path. Without the flag, a
///    revision landing after a viewer pick would stomp it.
///  - [hasTracks]: there is nothing to match against yet.
bool shouldApplySubtitlePreference({
  required bool viewerChose,
  required bool switchInFlight,
  required bool intentPending,
  required bool alreadyApplied,
  required bool hasTracks,
}) {
  if (viewerChose || switchInFlight || intentPending) return false;
  if (alreadyApplied || !hasTracks) return false;
  return true;
}

/// The `preferredSubtitle` for [fileId] in either root's generated shape.
///
/// The two queries differ only in their root field, and neither generated
/// type shares a supertype with the other, so this reads the decoded JSON map
/// rather than the generated classes. That keeps one function instead of two
/// and keeps this file free of generated imports.
///
/// Returns null for a missing root, a missing file, or a file with no
/// preference, which are the same answer to the caller: no opinion.
Map<String, dynamic>? preferredSubtitleJsonForFile(
  Map<String, dynamic> data, {
  required String root,
  required String fileId,
}) {
  final rootValue = data[root];
  if (rootValue is! Map<String, dynamic>) return null;

  final files = rootValue['files'];
  if (files is! List) return null;

  for (final file in files) {
    if (file is! Map<String, dynamic>) continue;
    if (file['id'] != fileId) continue;
    final preferred = file['preferredSubtitle'];
    return preferred is Map<String, dynamic> ? preferred : null;
  }
  return null;
}
