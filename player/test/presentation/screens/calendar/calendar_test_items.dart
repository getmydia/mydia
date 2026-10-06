import 'package:player/core/sources/source.dart';
import 'package:player/core/util/iso_date.dart';
import 'package:player/domain/sources/item.dart';

import '../sources/fake_media_source.dart';

/// One calendar listing entry. An episode of `A Show` unless [kind] says
/// otherwise; [playable] gives it a version to play.
ItemSummary calendarEntry(
  String id,
  DateTime airDate, {
  bool playable = false,
  ItemKind kind = ItemKind.episode,
  SourceId sourceId = fakeSourceId,
  String title = 'An Episode',
  int season = 1,
  int episode = 1,
}) {
  final isEpisode = kind == ItemKind.episode;
  return ItemSummary(
    ref: ItemRef(sourceId: sourceId, kind: kind, externalId: id),
    title: title,
    showTitle: isEpisode ? 'A Show' : null,
    parentIndex: isEpisode ? season : null,
    index: isEpisode ? episode : null,
    airDate: isoDate(airDate),
    defaultVersionId: playable ? 'file-$id' : null,
  );
}
