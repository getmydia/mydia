/// Optional features, reached through `MediaSource.as<T>()`. A source that
/// lists the matching `SourceCapability` returns itself for the interface.
library;

import '../../domain/sources/item.dart';

abstract interface class WatchedState {
  Future<void> setWatched(ItemRef ref, bool watched);
}

abstract interface class Searchable {
  Future<List<ItemSummary>> search(String query);
}
