/// Optional features, reached through `MediaSource.as<T>()`. A source that
/// lists the matching `SourceCapability` returns itself for the interface.
library;

import '../../domain/sources/hub.dart';
import '../../domain/sources/item.dart';

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
