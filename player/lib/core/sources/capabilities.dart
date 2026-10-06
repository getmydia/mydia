/// Optional features, reached through `MediaSource.as<T>()`. A source that
/// lists the matching `SourceCapability` returns itself for the interface.
library;

import '../../domain/models/download_option.dart';
import '../../domain/models/download_plan.dart';
import '../../domain/models/media_segment.dart';
import '../../domain/models/media_stream.dart';
import '../../domain/models/remote_device.dart';
import '../../domain/navigation/media_filter.dart';
import '../../domain/sources/collection.dart';
import '../../domain/sources/hub.dart';
import '../../domain/sources/item.dart';
import '../../domain/sources/library.dart';
import '../remote/remote_roster.dart';

abstract interface class WatchedState {
  Future<void> setWatched(ItemRef ref, bool watched);
}

abstract interface class Searchable {
  Future<List<ItemSummary>> search(String query);
}

/// What the viewer started and has not finished.
abstract interface class ContinueWatching {
  /// Most recent activity first, at most 20 items.
  Future<List<ItemSummary>> continueWatching();

  /// Whether [removeFromContinueWatching] can take [item] off the row. False
  /// for an entry the server offers no way to dismiss; its menu then offers
  /// Details only, rather than a Remove that the next refresh would undo.
  bool canRemoveFromContinueWatching(ItemSummary item);

  Future<void> removeFromContinueWatching(ItemRef ref);
}

/// The server's own home rows.
abstract interface class HomeHubs {
  /// In the server's order. Never holds Continue Watching or On Deck, which
  /// the Continue Watching row already shows.
  Future<List<Hub>> hubs();
}

/// Items like the one the viewer is looking at. A source implementing this
/// also lists [SourceCapability.similar].
abstract interface class Similar {
  /// At most 20.
  Future<List<ItemSummary>> similar(ItemRef ref);
}

/// A source implementing this also lists [SourceCapability.favorites].
abstract interface class Favorites {
  Future<void> setFavorite(ItemRef ref, bool favorite);
}

/// A source implementing this also lists [SourceCapability.nextUp].
abstract interface class NextUp {
  /// The episode the viewer would play next in [show], or null.
  Future<ItemSummary?> nextUp(ItemRef show);
}

/// What joined the server's libraries most recently. A source implementing
/// this also lists [SourceCapability.recentlyAdded].
abstract interface class RecentlyAdded {
  /// Newest first, at most 20.
  Future<List<ItemSummary>> recentlyAdded();
}

/// Intro and credits regions. A source implementing this also lists
/// [SourceCapability.skipSegments].
abstract interface class SkipSegments {
  /// Only actionable segments (see [MediaSegment.actionable]). Empty when
  /// the server has none or is too old to answer. Throws only on a
  /// transport or auth failure. [versionId] picks the file on servers that
  /// detect per file (Mydia); servers that detect per item ignore it.
  Future<List<MediaSegment>> skipSegments(ItemRef ref, {String? versionId});
}

/// Downloads to this device. A source implementing this also lists
/// [SourceCapability.downloadable].
abstract interface class Downloadable {
  /// What the viewer may pick. `DownloadOption.resolution` is the id
  /// [resolve] takes. Empty when the item has no file to download.
  Future<List<DownloadOption>> downloadOptions(ItemRef ref);

  /// Called on every start and restart; the result is never cached, because
  /// connections and tokens move under a long download.
  Future<DownloadPlan> resolve(ItemRef ref, String optionId);
}

/// Hands the server a position recorded while it was out of reach. A source
/// implementing this also lists [SourceCapability.progressSync].
abstract interface class ProgressSync {
  /// [watched] when the position crossed the 90% threshold.
  Future<void> pushProgress(
    ItemRef ref, {
    required int positionSeconds,
    required int durationSeconds,
    required bool watched,
  });
}

typedef SavedFilterQuery = ({LibraryRef library, BrowseQuery query});

/// A source implementing this also lists [SourceCapability.collections].
abstract interface class Collections {
  /// Every collection the viewer can see, in the server's order.
  Future<List<SourceCollection>> collections();

  /// [collectionId] is a `SourceCollection.id` of this source.
  Future<Page<ItemSummary>> collectionItems(
    String collectionId, {
    Cursor? cursor,
  });
}

/// A source implementing this also lists [SourceCapability.calendar].
abstract interface class Calendar {
  /// Episodes and movies airing or released from [start] to [end]
  /// inclusive, ordered by `ItemSummary.airDate`. Both are local dates.
  Future<List<ItemSummary>> calendar(DateTime start, DateTime end);
}

/// Saved filters live on the device (`FilterDestination`). A source
/// implementing this also lists [SourceCapability.savedFilters].
abstract interface class SavedFilters {
  /// The library and query that browse [filter]'s results, or null when
  /// this source has no library for its kind.
  SavedFilterQuery? filterQuery(MediaFilter filter);
}

/// A source implementing this also lists [SourceCapability.unwatchedListing].
abstract interface class UnwatchedListing {
  Future<Page<ItemSummary>> unwatched({Cursor? cursor});
}

/// A source implementing this also lists [SourceCapability.favoritesListing].
abstract interface class FavoritesListing {
  Future<Page<ItemSummary>> favorites({Cursor? cursor});
}

/// A source implementing this also lists [SourceCapability.mediaInfo].
abstract interface class MediaInfo {
  /// One entry per file of a movie or episode. Empty when it has none.
  Future<List<MediaFileInfo>> mediaInfo(ItemRef ref);
}

/// Other players signed into the same server, and this device's entry in
/// its device list. A source implementing this also lists
/// [SourceCapability.remoteTargets].
abstract interface class RemoteTargets {
  /// Built once per source object.
  DeviceRoster get roster;

  /// Registers this device's p2p node. Never throws.
  Future<bool> registerNode(String nodeId);

  /// The server's device list, revoked ones included, for its settings.
  Future<List<RemoteDevice>> devices();

  Future<bool> revokeDevice(String deviceId);
}
