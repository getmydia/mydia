/// Parsing for single entries of mpv's `track-list` property.
library;

/// The `(mpv track id, ffmpeg stream index)` pair for one `track-list`
/// entry, or null when the entry is not a subtitle read from the container.
///
/// Every argument is the raw string `NativePlayer.getProperty` returned for
/// `track-list/<i>/<field>`, which is "" for a field the entry does not have.
///
/// External tracks are skipped. A server-delivered subtitle reaches mpv
/// through `sub-add`, which makes it external, and an external track's
/// `ff-index` indexes its own file rather than the container, so it would
/// alias a real stream index.
MapEntry<String, int>? subtitleStreamIndexEntry({
  required String type,
  required String id,
  required String ffIndex,
  required String external,
}) {
  if (type != 'sub' || external == 'yes' || id.isEmpty) return null;
  final index = int.tryParse(ffIndex);
  if (index == null) return null;
  return MapEntry(id, index);
}
