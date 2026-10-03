/// What every source offers the screens, whatever server sits behind it.
///
/// Identity, capabilities and connection only, for now. Browsing members
/// arrive with their first consumer, the Plex and Stash screens.
library;

import 'source.dart';

/// Optional features a source may support. A screen checks before showing
/// one; adding a feature later means adding a value here, not reshaping
/// [MediaSource].
enum SourceCapability {
  progressReporting,
  watchedState,
  searchable,
  continueWatching,
  recentlyAdded,
  collections,
  facets,
  profiles,
  skipSegments,
  scrubThumbnails,
  downloadable,
  castable,
}

/// How the player currently reaches a source.
enum SourceConnectionStatus { connecting, local, remote, relay, unreachable }

abstract class MediaSource {
  const MediaSource();

  Source get source;

  SourceId get id => source.id;
  SourceKind get kind => source.kind;
  String get displayName => source.displayName;

  Set<SourceCapability> get capabilities;
  SourceConnectionStatus get connection;

  /// The object implementing capability [T], or null when unsupported.
  T? as<T extends Object>();
}
