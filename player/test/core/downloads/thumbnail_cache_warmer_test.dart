import 'package:file/memory.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/downloads/thumbnail_cache_warmer.dart';
import 'package:player/domain/models/download.dart';

/// Records the URLs it is asked for and, when [throwOnDownload] is set,
/// simulates an offline or 404 fetch. Every other member of the interface is
/// unused here and routed to [noSuchMethod].
class _FakeCacheManager implements BaseCacheManager {
  _FakeCacheManager({this.throwOnDownload = false});

  final bool throwOnDownload;
  final List<String> requested = <String>[];

  @override
  Future<FileInfo> downloadFile(
    String url, {
    String? key,
    Map<String, String>? authHeaders,
    bool force = false,
  }) async {
    requested.add(url);
    if (throwOnDownload) {
      throw Exception('network unavailable');
    }
    return FileInfo(
      MemoryFileSystem().file('unused'),
      FileSource.Online,
      DateTime(2026, 1, 1),
      url,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not used in tests');
}

DownloadTask _task({String? thumbnailUrl}) {
  return DownloadTask(
    id: 't1',
    mediaId: 'm1',
    title: 'Pilot',
    quality: '1080p',
    createdAt: DateTime(2026, 1, 1),
    thumbnailUrl: thumbnailUrl,
  );
}

void main() {
  test('fetches the thumbnail url when one is present', () async {
    final cache = _FakeCacheManager();

    await warmThumbnailCache(
      _task(thumbnailUrl: 'https://example.test/ep.jpg'),
      cache: cache,
    );

    expect(cache.requested, ['https://example.test/ep.jpg']);
  });

  test('fetches nothing when the thumbnail url is null', () async {
    final cache = _FakeCacheManager();

    await warmThumbnailCache(_task(), cache: cache);

    expect(cache.requested, isEmpty);
  });

  test('fetches nothing when the thumbnail url is empty', () async {
    final cache = _FakeCacheManager();

    await warmThumbnailCache(_task(thumbnailUrl: ''), cache: cache);

    expect(cache.requested, isEmpty);
  });

  test('returns normally when the fetch throws', () async {
    final cache = _FakeCacheManager(throwOnDownload: true);

    await expectLater(
      warmThumbnailCache(
        _task(thumbnailUrl: 'https://example.test/ep.jpg'),
        cache: cache,
      ),
      completes,
    );
  });
}
