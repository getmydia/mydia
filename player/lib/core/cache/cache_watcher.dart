import 'query_key.dart';

/// What the registry and the invalidator need from a watcher, whichever
/// store backs it: Mydia's `QueryWatcher` or a source's `SourceWatcher`.
abstract interface class CacheWatcher {
  QueryKey get key;

  /// See `QueryWatcher.refetchAutomatically`: false means the watcher
  /// declined, and the caller must clear the key's fetch-log entry instead.
  Future<bool> refetchAutomatically();
}
