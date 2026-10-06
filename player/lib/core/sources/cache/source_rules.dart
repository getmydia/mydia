/// The single mapping from a write on a source to the cached data it makes
/// stale. Add rules here, never at a call site.
///
/// Every target is a family on the written item's source. The rules do not
/// try to name the show or season of the item: refetching every live
/// watcher of a family costs a few requests for the screens on the
/// navigation stack, and the rest only lose their fetch-log entry.
library;

import '../../cache/invalidation_target.dart';
import '../source.dart';
import 'source_keys.dart';

abstract final class SourceRules {
  /// Watched state or progress changed, here or in the player.
  static Set<InvalidationTarget> watchedChanged(SourceId id) => {
        for (final op in const [
          SourceOps.item,
          SourceOps.children,
          SourceOps.browse,
          SourceOps.continueWatching,
          SourceOps.hubs,
          SourceOps.similar,
        ])
          SourceKeys.family(id, op),
      };

  static Set<InvalidationTarget> favoriteChanged(SourceId id) => {
        for (final op in const [
          SourceOps.item,
          SourceOps.browse,
          SourceOps.hubs,
        ])
          SourceKeys.family(id, op),
      };

  /// The rail itself and the hubs, which some servers build from it.
  static Set<InvalidationTarget> continueWatchingRemoved(SourceId id) => {
        SourceKeys.family(id, SourceOps.continueWatching),
        SourceKeys.family(id, SourceOps.hubs),
      };

  /// The periodic progress report refreshes nothing; playback finishing
  /// does, through [watchedChanged].
  static const Set<InvalidationTarget> progressSynced = <InvalidationTarget>{};
}
