/// Native half of `image_subtitle_sidecar.dart`: `package:http` for the
/// poll, a temp file for mpv.
library;

import 'dart:io';

import 'package:http/http.dart' as http;

import 'image_subtitle_sidecar.dart';

Future<SidecarFetch> fetchImageSidecar({
  required Uri url,
  required Map<String, String> headers,
  required bool Function() cancelled,
}) =>
    pollImageSidecar(
      url: url,
      headers: headers,
      cancelled: cancelled,
      get: _get,
      save: _save,
    );

Future<SidecarResponse> _get(Uri url, Map<String, String> headers) async {
  final response = await http.get(url, headers: headers);
  return SidecarResponse(
    status: response.statusCode,
    body: response.bodyBytes,
    retryAfter: parseRetryAfter(response.headers['retry-after']),
  );
}

// One directory per file, so discarding one never touches another.
Future<String> _save(List<int> bytes) async {
  final dir = await Directory.systemTemp.createTemp('mydia-subs-');
  final file = File('${dir.path}${Platform.pathSeparator}track.mks');
  await file.writeAsBytes(bytes, flush: true);
  return file.path;
}

Future<void> discardImageSidecar(String path) async {
  try {
    await File(path).parent.delete(recursive: true);
  } catch (_) {
    // A file mpv still holds open on Windows, or one already gone. The OS
    // clears its temp directory eventually; this is not worth a failure.
  }
}
