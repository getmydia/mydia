import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/graphql/watch/controller_watcher.dart';
import '../../../core/graphql/watch/query_key.dart';
import '../../../core/graphql/watch/query_watcher.dart';
import '../../../domain/models/continue_watching_item.dart';

part 'continue_watching_controller.g.dart';

const int _pageSize = 20;

const _flatPageInfoKey = '__flatPageInfo';

const String continueWatchingListQuery = r'''
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
}
