/// Fetching an embedded bitmap subtitle track for a streamed source.
///
/// The server stream-copies the track into a subtitle-only Matroska file
/// inside the HLS session, `subs_<index>.mks`, and answers 503 until the
/// copy is done: it reads the whole source, which on a large remux takes
/// minutes. The player polls, saves the finished file locally, and hands
/// mpv the local path. mpv reads an external subtitle file whole, inside
/// `sub-add`, on its playback thread, so fetching it over the network there
/// would freeze the picture for as long as the download took.
library;

import 'image_subtitle_sidecar_stub.dart'
    if (dart.library.io) 'image_subtitle_sidecar_native.dart' as platform;

/// How long a pick waits for the server's copy before giving up. The copy
/// keeps running server-side, so picking the track again later is served
/// from its cache.
const kImageSidecarTimeLimit = Duration(minutes: 3);

/// What a sidecar fetch came to.
sealed class SidecarFetch {
  const SidecarFetch();
}

/// Saved locally at [path], ready for `sub-add`.
final class SidecarReady extends SidecarFetch {
  const SidecarReady(this.path);

  final String path;

  @override
  String toString() => 'SidecarReady($path)';
}

/// The server answered 404: it predates bitmap sidecars, or does not know
/// the track. There the track plays only at Original.
final class SidecarUnsupported extends SidecarFetch {
  const SidecarUnsupported();

  @override
  String toString() => 'SidecarUnsupported()';
}

/// The copy failed, the time limit passed, or the request itself failed.
final class SidecarFailed extends SidecarFetch {
  const SidecarFailed(this.reason);

  final String reason;

  @override
  String toString() => 'SidecarFailed($reason)';
}

/// A newer pick, or the screen going away, made this one moot.
final class SidecarCancelled extends SidecarFetch {
  const SidecarCancelled();

  @override
  String toString() => 'SidecarCancelled()';
}

/// The session-relative name the server serves embedded stream
/// [streamIndex] under. Matches `SessionSubtitles.image_filename/1`.
String imageSidecarName(String streamIndex) => 'subs_$streamIndex.mks';

/// One HTTP answer, reduced to what the poll reads.
class SidecarResponse {
  const SidecarResponse({
    required this.status,
    this.body = const [],
    this.retryAfter,
  });

  final int status;
  final List<int> body;
  final Duration? retryAfter;
}

typedef SidecarGet = Future<SidecarResponse> Function(
  Uri url,
  Map<String, String> headers,
);

typedef SidecarSave = Future<String> Function(List<int> bytes);

/// Reads a `Retry-After` header given in seconds, clamped to 1-10 s. An
/// HTTP-date, or anything else unreadable, gives null.
Duration? parseRetryAfter(String? header) {
  final seconds = int.tryParse(header?.trim() ?? '');
  if (seconds == null) return null;
  return Duration(seconds: seconds.clamp(1, 10));
}

/// Polls [url] until the server has the sidecar ready, then saves it.
///
/// Platform-neutral so it can be tested with fakes; the native side wires
/// in `package:http` and a temp file. [cancelled] is checked before every
/// request and after every answer, so a superseded pick stops at once and
/// saves nothing.
Future<SidecarFetch> pollImageSidecar({
  required Uri url,
  required Map<String, String> headers,
  required SidecarGet get,
  required SidecarSave save,
  required bool Function() cancelled,
  Future<void> Function(Duration) wait = Future.delayed,
  DateTime Function() now = DateTime.now,
  Duration limit = kImageSidecarTimeLimit,
  Duration defaultRetry = const Duration(seconds: 2),
}) async {
  final deadline = now().add(limit);
  while (true) {
    if (cancelled()) return const SidecarCancelled();

    final SidecarResponse response;
    try {
      response = await get(url, headers);
    } catch (e) {
      return SidecarFailed('$e');
    }
    if (cancelled()) return const SidecarCancelled();

    switch (response.status) {
      case 200:
        try {
          return SidecarReady(await save(response.body));
        } catch (e) {
          return SidecarFailed('$e');
        }
      case 404:
        return const SidecarUnsupported();
      case 503:
        // p2p answers carry no headers, so the default covers them.
        final delay = response.retryAfter ?? defaultRetry;
        if (now().add(delay).isAfter(deadline)) {
          return const SidecarFailed('timed out waiting for the server');
        }
        await wait(delay);
      default:
        return SidecarFailed('HTTP ${response.status}');
    }
  }
}

/// Fetches the sidecar at [url] and saves it locally. Web has no mpv to
/// hand it to, so there it is always [SidecarUnsupported].
Future<SidecarFetch> fetchImageSidecar({
  required Uri url,
  required Map<String, String> headers,
  required bool Function() cancelled,
}) =>
    platform.fetchImageSidecar(
      url: url,
      headers: headers,
      cancelled: cancelled,
    );

/// Deletes a file [fetchImageSidecar] saved. Never throws.
Future<void> discardImageSidecar(String path) =>
    platform.discardImageSidecar(path);
