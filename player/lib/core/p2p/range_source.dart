import 'package:player/core/p2p/p2p_range_stream.dart';

/// Where the proxy gets the body of a byte-range response.
abstract interface class RangeSource {
  /// The body, in order. Pull-driven: nothing is read while the listener
  /// is paused. Listen once.
  Stream<List<int>> bytes();

  /// Stops producing, releases what is held, and cancels the upstream.
  /// Idempotent.
  Future<void> cancel();

  /// Bytes written to disk ahead of the reader.
  int get spooledBytes;

  /// Times the spool was emptied to stay inside its disk budget.
  int get truncations;
}

/// Hands upstream chunks straight to the listener, so the client's socket
/// paces the server.
class PassThroughSource implements RangeSource {
  PassThroughSource(this._upstream);

  final P2pRangeStream _upstream;
  var _cancelled = false;

  @override
  int get spooledBytes => 0;

  @override
  int get truncations => 0;

  @override
  Stream<List<int>> bytes() async* {
    try {
      while (!_cancelled) {
        final chunk = await _upstream.nextChunk();
        if (chunk == null) return;
        yield chunk;
      }
    } finally {
      _upstream.cancel();
    }
  }

  @override
  Future<void> cancel() async {
    _cancelled = true;
    _upstream.cancel();
  }
}
