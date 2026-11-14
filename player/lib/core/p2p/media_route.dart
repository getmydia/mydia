// The proxy's URL table, in both directions.
//
// Native serves these paths from a loopback HTTP server, a browser serves them
// from a Service Worker, and the two have to agree on them exactly: the URL a
// video element is handed on one platform is parsed by the other's dispatcher.
// So the table lives here once. [MediaRoutes] builds the URLs and
// [MediaRoutes.resolve] takes them apart again, and neither implementation
// carries a copy of the prefix chain.
//
// Deliberately free of `dart:io` and `dart:js_interop`: this file is imported
// by both.

import 'dart:convert';

/// How a matched route's bytes are fetched over p2p.
enum MediaRouteKind {
  /// A manifest or a segment: one bounded response, requested whole.
  hls,

  /// A file's bytes: long, range-seekable, streamed chunk by chunk.
  byteStream,
}

/// The result of matching a request path against the table.
sealed class MediaRoute {
  const MediaRoute();
}

/// A path that names a p2p session and a path inside it.
final class MediaRouteMatch extends MediaRoute {
  /// Session the p2p request is made against. Direct playback and download
  /// proxying reuse the HLS session channel through a prefixed id.
  final String sessionId;

  /// Path within the session, as the remote instance expects it.
  final String path;

  final MediaRouteKind kind;

  const MediaRouteMatch({
    required this.sessionId,
    required this.path,
    required this.kind,
  });
}

/// A path no route claims, or one shaped wrong.
///
/// [message] is served as the response body, so it is what a developer sees
/// when a URL is built incorrectly.
final class MediaRouteFailure extends MediaRoute {
  final int statusCode;
  final String message;

  const MediaRouteFailure(this.statusCode, this.message);
}

/// Status codes the table produces. Spelled out rather than taken from
/// `HttpStatus`, which lives in `dart:io` and would drag this file onto one
/// platform.
const _badRequest = 400;
const _notFound = 404;

abstract final class MediaRoutes {
  /// Session id prefixes of the byte-stream routes.
  static const directSessionPrefix = 'direct:';
  static const downloadSessionPrefix = 'download:';
  static const peerFileSessionPrefix = 'peerfile:';

  /// URL of a session's HLS manifest.
  static String hls(String base, String sessionId) =>
      '$base/hls/$sessionId/index.m3u8';

  /// Base the manifest's relative segment URLs resolve against.
  static String hlsBase(String base, String sessionId) =>
      '$base/hls/$sessionId/';

  /// URL of a file inside a session other than its manifest, such as a
  /// bitmap subtitle sidecar.
  static String hlsFile(String base, String sessionId, String name) =>
      '${hlsBase(base, sessionId)}$name';

  /// URL that streams a media file's own bytes, with no transcoding.
  static String directStream(String base, String fileId) =>
      '$base/direct/$fileId/stream';

  /// URL that proxies a finished transcode job's file.
  static String download(String base, String jobId) =>
      '$base/download/$jobId/file';

  /// How a paired player's file path travels in a URL and to its host:
  /// base64url of its UTF-8, without padding. A path holds spaces, `#`, `?`,
  /// backslashes and non-ASCII letters, none of which survive a URL segment
  /// as they are, and the host matches the decoded string exactly.
  static String peerFileToken(String path) =>
      base64Url.encode(utf8.encode(path)).replaceAll('=', '');

  /// URL that streams the file at [path] lent by a paired player, read from
  /// its account [accountId] (the host's own id for it).
  static String peerFile(String base, String accountId, String path) =>
      '$base/peerfile/$accountId/${peerFileToken(path)}/stream';

  /// Match [path] against the table. [path] is the request path with any
  /// platform prefix already removed, so it starts at `/hls/`, `/direct/`,
  /// `/download/` or `/peerfile/`.
  static MediaRoute resolve(String path) {
    if (path.startsWith('/hls/')) {
      final parts = path.substring('/hls/'.length).split('/');
      if (parts.length < 2) {
        return const MediaRouteFailure(
          _badRequest,
          'Invalid HLS path format. Expected: /hls/{session_id}/{path}',
        );
      }

      final sessionId = parts.first;
      final hlsPath = parts.skip(1).join('/');
      if (sessionId.isEmpty || hlsPath.isEmpty) {
        return const MediaRouteFailure(
          _badRequest,
          'Session ID and path are required',
        );
      }

      return MediaRouteMatch(
        sessionId: sessionId,
        path: hlsPath,
        kind: MediaRouteKind.hls,
      );
    }

    if (path.startsWith('/direct/')) {
      return _byteStream(
        path,
        prefix: '/direct/',
        shape: '/direct/{file_id}/stream',
        idLabel: 'File ID',
        sessionPrefix: directSessionPrefix,
        remotePath: 'stream',
      );
    }

    if (path.startsWith('/download/')) {
      return _byteStream(
        path,
        prefix: '/download/',
        shape: '/download/{job_id}/file',
        idLabel: 'Job ID',
        sessionPrefix: downloadSessionPrefix,
        remotePath: 'file',
      );
    }

    if (path.startsWith('/peerfile/')) {
      return _byteStream(
        path,
        prefix: '/peerfile/',
        shape: '/peerfile/{account_id}/{path_token}/stream',
        idLabel: 'Account ID',
        sessionPrefix: peerFileSessionPrefix,
        remotePath: null,
      );
    }

    return const MediaRouteFailure(_notFound, 'Not Found');
  }

  /// The byte-stream routes differ only in their wording, their session
  /// prefix and the path asked of the remote, so they share one parser. A
  /// null [remotePath] means the remote path is the segment after the id,
  /// as for a peer file, whose path token is what the host reads.
  static MediaRoute _byteStream(
    String path, {
    required String prefix,
    required String shape,
    required String idLabel,
    required String sessionPrefix,
    required String? remotePath,
  }) {
    final parts = path.substring(prefix.length).split('/');
    final tokenPath = remotePath == null;
    if (parts.length < (tokenPath ? 3 : 2) || (tokenPath && parts[1].isEmpty)) {
      final kind = prefix.replaceAll('/', '');
      return MediaRouteFailure(
        _badRequest,
        'Invalid $kind path format. Expected: $shape',
      );
    }

    final id = parts.first;
    if (id.isEmpty) {
      return MediaRouteFailure(_badRequest, '$idLabel is required');
    }

    return MediaRouteMatch(
      sessionId: '$sessionPrefix$id',
      path: remotePath ?? parts[1],
      kind: MediaRouteKind.byteStream,
    );
  }
}
