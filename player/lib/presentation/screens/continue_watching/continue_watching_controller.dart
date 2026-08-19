import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/graphql/watch/controller_watcher.dart';
import '../../../core/graphql/watch/query_key.dart';
import '../../../core/graphql/watch/query_watcher.dart';
import '../../../domain/models/continue_watching_item.dart';
import 'continue_watching_actions.dart' as actions;

part 'continue_watching_controller.g.dart';

const int _pageSize = 20;

const _flatPageInfoKey = '__flatPageInfo';

const String continueWatchingListQuery = r'''
query ContinueWatchingList($first: Int, $after: String) {
  continueWatching(first: $first, after: $after) {
    id
    type
    title
    state
    artwork {
      posterUrl
      backdropUrl
      thumbnailUrl
    }
    progress {
      positionSeconds
      durationSeconds
      percentage
      watched
      lastWatchedAt
    }
    showId
    showTitle
    seasonNumber
    episodeNumber
    files {
      id
      resolution
      codec
      audioCodec
      hdrFormat
      size
      bitrate
      directPlaySupported
      streamUrl
      directPlayUrl
    }
  }
}
''';

/// The pre-merged-rail shape, for a server older than this build.
const String continueWatchingListQueryLegacy = r'''
query ContinueWatchingList($first: Int, $after: String) {
  continueWatching(first: $first, after: $after) {
    id
    type
    title
    artwork {
      posterUrl
      backdropUrl
      thumbnailUrl
    }
    progress {
      positionSeconds
      durationSeconds
      percentage
      watched
      lastWatchedAt
    }
    showId
    showTitle
    seasonNumber
    episodeNumber
    files {
      id
      resolution
      codec
      audioCodec
      hdrFormat
      size
      bitrate
      directPlaySupported
      streamUrl
      directPlayUrl
    }
  }
}
''';

class ContinueWatchingData {
  final List<ContinueWatchingItem> items;
  final bool hasMore;
  final String? endCursor;

  const ContinueWatchingData({
    required this.items,
    required this.hasMore,
    this.endCursor,
  });

  /// Exists so an optimistic edit to [items] cannot silently drop the paging
  /// state, which would strand the viewer on page one with no way to load more.
  ContinueWatchingData copyWith({
    List<ContinueWatchingItem>? items,
    bool? hasMore,
    String? endCursor,
  }) {
    return ContinueWatchingData(
      items: items ?? this.items,
      hasMore: hasMore ?? this.hasMore,
      endCursor: endCursor ?? this.endCursor,
    );
  }

  bool get isEmpty => items.isEmpty;
}

String _encodeOffsetCursor(int offset) =>
    base64Encode(utf8.encode('cursor:$offset'));

ContinueWatchingData _parseContinueWatching(Map<String, dynamic> data) {
  const field = 'continueWatching';
  final items = (data[field] as List<dynamic>? ?? const [])
      .cast<Map<String, dynamic>>()
      .map(ContinueWatchingItem.fromJson)
      .toList();

  final pageInfo = data[_flatPageInfoKey] as Map<String, dynamic>?;
  final hasMore = pageInfo != null
      ? pageInfo['hasNextPage'] as bool? ?? false
      : items.length >= _pageSize;
  final endCursor = pageInfo != null
      ? pageInfo['endCursor'] as String?
      : (items.isEmpty ? null : _encodeOffsetCursor(items.length - 1));

  return ContinueWatchingData(
    items: items,
    hasMore: hasMore,
    endCursor: endCursor,
  );
}

Map<String, dynamic>? _mergeContinueWatching(
  Map<String, dynamic>? previous,
  Map<String, dynamic>? fetched,
) {
  const field = 'continueWatching';
  if (fetched == null) return previous;
  if (previous == null) return fetched;

  final previousList = previous[field] as List<dynamic>? ?? const [];
  final fetchedList = fetched[field] as List<dynamic>? ?? const [];
  final merged = [...previousList, ...fetchedList];

  return {
    ...fetched,
    field: merged,
    _flatPageInfoKey: {
      'hasNextPage': fetchedList.length >= _pageSize,
      'endCursor':
          merged.isEmpty ? null : _encodeOffsetCursor(merged.length - 1),
    },
  };
}

@riverpod
class ContinueWatchingController extends _$ContinueWatchingController {
  late QueryWatcher<ContinueWatchingData> _watcher;
  bool _loadingMore = false;
  late bool _hasPaginated;

  Map<String, dynamic> _variables({String? after}) => {
        'first': _pageSize,
        if (after != null) 'after': after,
      };

  @override
  Stream<ContinueWatchingData> build() {
    _hasPaginated = false;

    _watcher = createWatcher<ContinueWatchingData>(
      ref,
      key: QueryKeys.continueWatchingList,
      document: gql(continueWatchingListQuery),
      fallbackDocument: gql(continueWatchingListQueryLegacy),
      variables: _variables(),
      parse: _parseContinueWatching,
      canRefetch: () => !_hasPaginated,
    );
    return _watcher.stream;
  }

  Future<void> refresh() {
    _hasPaginated = false;
    return _watcher.refetch();
  }

  Future<void> loadMore() async {
    if (_loadingMore) return;

    final current = state.value;
    final cursor = current?.endCursor;
    if (current == null || !current.hasMore || cursor == null) return;

    _loadingMore = true;
    try {
      await _watcher.fetchMore(
        FetchMoreOptions(
          variables: _variables(after: cursor),
          updateQuery: _mergeContinueWatching,
        ),
      );
      _hasPaginated = true;
    } catch (error) {
      debugPrint('ContinueWatchingController.loadMore failed: $error');
    } finally {
      _loadingMore = false;
    }
  }

  /// Hides a title from Continue Watching and drops its card from the grid.
  ///
  /// [key] is `ContinueWatchingItem.continueWatchingKey`, the show for an
  /// episode card. Matching on the item's own id would never remove an episode
  /// card, since the id being hidden is its show's.
  ///
  /// The splice below is doing more work here than on the home rail. Once the
  /// viewer has paged, `canRefetch` returns false and the invalidation only
  /// clears the fetch log rather than refetching, so nothing on the server
  /// side corrects a splice that misses until this screen is torn down.
  Future<void> removeFromContinueWatching(String key) async {
    final currentState = state.value;
    if (currentState == null) return;

    state = AsyncValue.data(
      currentState.copyWith(
        items:
            currentState.items.where((item) => !item.dismissedBy(key)).toList(),
      ),
    );

    try {
      await actions.removeFromContinueWatching(ref, key);
    } catch (_) {
      final latest = state.value ?? currentState;
      state = AsyncValue.data(
        latest.copyWith(
          items: restoreFailedRemoval(
            snapshot: currentState.items,
            latest: latest.items,
            key: key,
          ),
        ),
      );
      rethrow;
    }
  }
}
