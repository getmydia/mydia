/// One HTTP fetch of a download, resuming from what is already on disk.
library;

import 'dart:io';

import 'package:dio/dio.dart';

/// Flush to disk this often so a fast network cannot outrun a slow disk.
const _flushEvery = 4 * 1024 * 1024;

final _urlQuery = RegExp(r'''(https?://[^\s?'")>]*)\?[^\s'")>]*''');

/// [text] with the query string removed from every URL in it. A media URL may
/// carry its token in the query, and an error saved on a task is shown in the
/// UI and kept in Hive.
String stripUrlQueries(String text) =>
    text.replaceAllMapped(_urlQuery, (m) => m.group(1)!);

class RangeFetchResult {
  const RangeFetchResult({
    required this.bytesOnDisk,
    required this.statusCode,
    this.total,
  });

  final int bytesOnDisk;
  final int statusCode;

  /// The whole file's size when the response said, else null.
  final int? total;
}

/// Fetches [url] into [file], asking for the bytes from [from] on.
///
/// A server that ignores `Range` answers 200 with the whole file. Appending
/// that to the partial would corrupt it, so a 200 truncates and starts over.
/// Writes the body as it streams, so a cancel or a dropped connection
/// leaves every byte that arrived on disk for the next attempt.
///
/// A cancel always surfaces as a [DioException] of type
/// [DioExceptionType.cancel], also mid-body: Dio only aborts the underlying
/// request for a streamed response, so the body stream may error with an
/// `HttpException` or simply end early, and both are reported as the cancel.
Future<RangeFetchResult> fetchRange(
  Dio dio, {
  required String url,
  required Map<String, String> headers,
  required File file,
  required int from,
  required CancelToken cancelToken,
  required Future<void> Function(int bytesOnDisk, int? total) onProgress,
}) async {
  final response = await dio.get<ResponseBody>(
    url,
    cancelToken: cancelToken,
    options: Options(
      responseType: ResponseType.stream,
      headers: {...headers, if (from > 0) 'Range': 'bytes=$from-'},
    ),
  );
  final status = response.statusCode ?? 0;
  final resume = from > 0 && status == 206;
  var onDisk = resume ? from : 0;
  final length = int.tryParse(
    response.headers.value(Headers.contentLengthHeader) ?? '',
  );
  final total = length == null ? null : onDisk + length;

  final sink = file.openWrite(mode: resume ? FileMode.append : FileMode.write);
  var unflushed = 0;
  try {
    await for (final chunk in response.data!.stream) {
      if (cancelToken.isCancelled) break;
      sink.add(chunk);
      onDisk += chunk.length;
      unflushed += chunk.length;
      if (unflushed >= _flushEvery) {
        await sink.flush();
        unflushed = 0;
      }
      await onProgress(onDisk, total);
    }
  } catch (e) {
    // A cancel aborts the request, which errors the body stream.
    if (!cancelToken.isCancelled) {
      if (e is DioException) rethrow;
      // Dio does not wrap an error from a streamed body, so a dropped
      // connection arrives as an HttpException, SocketException or the like.
      // Its text names the URL, and a URL can carry a token in its query, so
      // only the type survives.
      throw DioException(
        requestOptions: response.requestOptions,
        type: DioExceptionType.connectionError,
        error: e,
        message: 'Connection lost (${e.runtimeType})',
      );
    }
  } finally {
    await sink.flush();
    await sink.close();
  }
  final cancelled = cancelToken.cancelError;
  if (cancelled != null) throw cancelled;
  return RangeFetchResult(
    bytesOnDisk: onDisk,
    statusCode: status,
    total: total,
  );
}
