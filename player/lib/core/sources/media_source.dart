/// What every source offers the screens, whatever server sits behind it.
library;

import 'package:flutter/foundation.dart';

import '../../domain/sources/item.dart';
import '../../domain/sources/library.dart';
import 'source.dart';

/// Optional features a source may support. A screen checks before showing
/// one; adding a feature later means adding a value here, not reshaping
/// [MediaSource].
enum SourceCapability {
  progressReporting,
  progressSync,
  watchedState,
  searchable,
  continueWatching,
  hubs,
  skipSegments,
  downloadable,
  castable,
  similar,
  favorites,
  nextUp,
  recentlyAdded,
  collections,
  calendar,
  savedFilters,
  unwatchedListing,
  favoritesListing,
  mediaInfo,
  remoteTargets,
}

/// How the player currently reaches a source.
enum SourceConnectionStatus { connecting, local, remote, relay, unreachable }

/// What the image cache fetches for one piece of artwork.
@immutable
class ArtworkRequest {
  const ArtworkRequest({
    required this.url,
    required this.headers,
    required this.cacheKey,
  });

  final String url;

  /// Carries the credential, which never goes in [url].
  final Map<String, String> headers;

  /// `sourceId|path|width`: independent of the connection, so an upgrade
  /// from relay to local does not refetch every poster.
  final String cacheKey;
}

abstract class MediaSource {
  const MediaSource();

  Source get source;

  SourceId get id => source.id;
  SourceKind get kind => source.kind;
  String get displayName => source.displayName;

  Set<SourceCapability> get capabilities;
  SourceConnectionStatus get connection;

  /// [connection], as something the switcher can listen to.
  ValueListenable<SourceConnectionStatus> get statusListenable;

  /// The object implementing capability [T], or null when unsupported.
  T? as<T extends Object>();

  Future<List<Library>> libraries();

  Future<Page<ItemSummary>> browse(
    LibraryRef library,
    BrowseQuery query, {
    Cursor? cursor,
  });

  Future<ItemDetail> item(ItemRef ref);

  Future<Page<ItemSummary>> children(ItemRef parent, {Cursor? cursor});

  /// Null when the source has no artwork for [art].
  Future<ArtworkRequest?> artwork(ArtworkRef art, {required int width});

  /// Releases timers and connections. Called when the source is removed.
  void dispose() {}
}
