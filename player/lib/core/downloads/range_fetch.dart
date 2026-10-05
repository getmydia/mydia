/// One HTTP fetch of a download, resuming from what is already on disk.
library;

import 'dart:io';

import 'package:dio/dio.dart';

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
  try {
    await for (final chunk in response.data!.stream) {
      sink.add(chunk);
      onDisk += chunk.length;
      await onProgress(onDisk, total);
    }
  } finally {
    await sink.flush();
    await sink.close();
  }
  return RangeFetchResult(
    bytesOnDisk: onDisk,
    statusCode: status,
    total: total,
  );
}
