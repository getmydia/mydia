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

  Future<void> removeFromContinueWatching(ItemRef ref);
}

/// The server's own home rows.
abstract interface class HomeHubs {
  /// In the server's order. Never holds Continue Watching or On Deck, which
  /// the Continue Watching row already shows.
  Future<List<Hub>> hubs();
}
