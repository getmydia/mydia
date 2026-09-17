import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/update/update_feed_client.dart';
import 'package:player/core/update/update_track.dart';

const _feed = {
  'generated_at': '2026-09-17T00:00:00Z',
  'platforms': {
    'android': {
      'stable': {
        'version': '0.15.0',
        'build': 1500900,
        'url': 'https://example.invalid/mydia-player-android-v0.15.0.apk',
        'size': 68000000,
        'sha256': null,
        'notes_url': 'https://example.invalid/releases/tag/v0.15.0',
        'published_at': '2026-09-01T10:00:00Z',
      },
      'dev': {
        'version': '0.16.0-dev.7',
        'build': 1600007,
        'url': 'https://example.invalid/android/dev.apk',
        'size': 68200000,
        'sha256': 'abc123',
        'notes_url': 'https://example.invalid/commits/master',
        'published_at': '2026-09-15T08:00:00Z',
      },
    },
    'windows': {},
  },
};

/// Returns [body] as the JSON response for any request, with [status].
class _StubAdapter implements HttpClientAdapter {
  _StubAdapter(this.body, this.status);

  final Object body;
  final int status;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final bytes = utf8.encode(jsonEncode(body));
    return ResponseBody.fromBytes(
      bytes,
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }
}

Dio _dioReturning(Object body, {int status = 200}) {
  final dio = Dio();
  dio.httpClientAdapter = _StubAdapter(body, status);
  return dio;
}

void main() {
  test('resolves the entry for a platform and track', () async {
    final client = UpdateFeedClient(dio: _dioReturning(_feed));
    final entry =
        await client.fetch(track: UpdateTrack.dev, platform: 'android');

    expect(entry, isNotNull);
    expect(entry!.version, '0.16.0-dev.7');
    expect(entry.build, 1600007);
    expect(entry.sha256, 'abc123');
  });

  test('a track the platform does not publish is null, not an error', () async {
    final client = UpdateFeedClient(dio: _dioReturning(_feed));
    expect(await client.fetch(track: UpdateTrack.beta, platform: 'android'),
        isNull);
    expect(await client.fetch(track: UpdateTrack.stable, platform: 'windows'),
        isNull);
  });

  test('an unknown platform is null', () async {
    final client = UpdateFeedClient(dio: _dioReturning(_feed));
    expect(await client.fetch(track: UpdateTrack.stable, platform: 'toaster'),
        isNull);
  });

  test('a failed request is null rather than a throw', () async {
    final client = UpdateFeedClient(dio: _dioReturning({}, status: 503));
    expect(await client.fetch(track: UpdateTrack.stable, platform: 'android'),
        isNull);
  });

  test('a malformed payload is null rather than a throw', () async {
    final client = UpdateFeedClient(dio: _dioReturning('not a feed'));
    expect(await client.fetch(track: UpdateTrack.stable, platform: 'android'),
        isNull);
  });

  test('toAppUpdate carries the download and the notes', () async {
    final client = UpdateFeedClient(dio: _dioReturning(_feed));
    final update =
        (await client.fetch(track: UpdateTrack.stable, platform: 'android'))!
            .toAppUpdate();

    expect(update.version, '0.15.0');
    expect(update.downloadUrl, endsWith('.apk'));
    expect(update.downloadSize, 68000000);
    expect(update.releaseNotesUrl, contains('releases/tag'));
  });
}
