import 'dart:typed_data';

import 'package:player/native/lib.dart' show FlutterHlsResponseHeader;

/// One byte-range response from the server, pulled a chunk at a time.
///
/// Pulling is the flow control. While nobody calls [nextChunk], the server
/// is held back, so the bytes do not pile up in this process.
abstract interface class P2pRangeStream {
  FlutterHlsResponseHeader get header;

  /// The next chunk, or null once the stream has ended, failed or been
  /// cancelled.
  Future<Uint8List?> nextChunk();

  /// Stops the stream and tells the server to stop sending. Idempotent, and
  /// wakes a pending [nextChunk] with null.
  void cancel();
}
