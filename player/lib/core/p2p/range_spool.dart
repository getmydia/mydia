import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:player/core/p2p/disk_space.dart';
import 'package:player/core/p2p/p2p_range_stream.dart';
import 'package:player/core/p2p/range_source.dart';

const _mib = 1024 * 1024;
const _gib = 1024 * _mib;

/// How much disk a [RangeSpool] may use.
class RangeSpoolPolicy {
  const RangeSpoolPolicy({
    this.reserveFloorBytes = 2 * _gib,
    this.reserveFraction = 0.10,
    this.checkIntervalBytes = 64 * _mib,
    this.readChunkBytes = _mib,
  });

  /// Free space always left on the volume: at least this many bytes...
  final int reserveFloorBytes;

  /// ...or this share of the volume, whichever is larger.
  final double reserveFraction;

  /// Bytes spooled between free-space checks.
  final int checkIntervalBytes;

  /// Largest piece the reader hands to the socket at once.
  final int readChunkBytes;

  /// Whether a spool may keep growing on a volume with [space].
  bool allowsGrowth(DiskSpace space) {
    final reserve = max(
      reserveFloorBytes,
      (space.total * reserveFraction).floor(),
    );
    return space.free > reserve;
  }
}

/// Downloads a byte range to a temp file as fast as the link allows, and
/// serves it to the client at the client's own pace.
///
/// This is what lets a stream that is never seeked download the whole file
/// ahead of playback without holding it in memory. The download waits only
/// when the disk budget runs out: the reader then drains the file, the file
/// is emptied, and the download carries on.
class RangeSpool implements RangeSource {
  RangeSpool._(
    this._upstream,
    this.file,
    this._writer,
    this._reader,
    this._diskSpace,
    this._policy,
  );

  /// Starts spooling [upstream] into a new file under [directory]. Returns
  /// null when that is not possible: the volume is inside its reserve, its
  /// space cannot be measured, or the file cannot be created. [upstream] is
  /// left untouched then, for the caller to serve another way.
  static Future<RangeSpool?> open({
    required P2pRangeStream upstream,
    required Directory directory,
    required DiskSpaceProbe diskSpace,
    RangeSpoolPolicy policy = const RangeSpoolPolicy(),
  }) async {
    final space = await diskSpace(directory.path);
    if (space == null || !policy.allowsGrowth(space)) return null;

    final file = File('${directory.path}/${_uniqueName()}.part');
    RandomAccessFile? writer;
    try {
      writer = await file.open(mode: FileMode.write);
      final reader = await file.open(mode: FileMode.read);
      return RangeSpool._(upstream, file, writer, reader, diskSpace, policy)
        .._start();
    } on FileSystemException catch (e) {
      debugPrint('[RangeSpool] Could not create ${file.path}: $e');
      await writer?.close();
      await _deleteQuietly(file);
      return null;
    }
  }

  final P2pRangeStream _upstream;

  /// The file being spooled to.
  final File file;

  // Two handles: one RandomAccessFile cannot run two async operations at
  // once, and the writer and reader run concurrently.
  final RandomAccessFile _writer;
  final RandomAccessFile _reader;
  final DiskSpaceProbe _diskSpace;
  final RangeSpoolPolicy _policy;

  /// Bytes in the file, and how many of them have been served. Both count
  /// from the start of the file, which is reset each time it is emptied.
  var _written = 0;
  var _served = 0;
  var _sinceCheck = 0;

  var _spooled = 0;
  var _truncations = 0;
  var _upstreamDone = false;
  var _cancelled = false;
  var _readerBusy = false;
  var _readerClosed = false;

  Completer<void>? _dataWaiter;
  Completer<void>? _drainWaiter;
  final _pumpDone = Completer<void>();
  Future<void>? _cancelling;

  static final _random = Random.secure();

  @override
  int get spooledBytes => _spooled;

  @override
  int get truncations => _truncations;

  void _start() => unawaited(_pump().whenComplete(_pumpDone.complete));

  Future<void> _pump() async {
    try {
      while (!_cancelled) {
        if (_sinceCheck >= _policy.checkIntervalBytes) {
          _sinceCheck = 0;
          if (!await _hasRoom()) await _drainThenEmpty();
          if (_cancelled) break;
        }

        final chunk = await _upstream.nextChunk();
        if (chunk == null || _cancelled) break;

        await _writer.writeFrom(chunk);
        _written += chunk.length;
        _spooled += chunk.length;
        _sinceCheck += chunk.length;
        _wake(_dataWaiter);
      }
    } on FileSystemException catch (e) {
      // The reader still serves what reached the disk; the response then
      // ends short and the player reconnects.
      debugPrint('[RangeSpool] Write failed for ${file.path}: $e');
      _upstream.cancel();
    } finally {
      _upstreamDone = true;
      _wake(_dataWaiter);
    }
  }

  Future<bool> _hasRoom() async {
    final space = await _diskSpace(file.parent.path);
    return space != null && _policy.allowsGrowth(space);
  }

  /// Waits for the reader to serve everything written, then empties the
  /// file so the download can use that space again.
  Future<void> _drainThenEmpty() async {
    while (!_cancelled && _served < _written) {
      final waiter = _drainWaiter = Completer<void>();
      await waiter.future;
    }
    if (_cancelled) return;

    await _writer.truncate(0);
    await _writer.setPosition(0);
    _written = 0;
    _served = 0;
    _truncations++;
  }

  @override
  Stream<List<int>> bytes() async* {
    while (!_cancelled) {
      if (_served < _written) {
        final chunk = await _read(
          min(_policy.readChunkBytes, _written - _served),
        );
        if (chunk == null) return;
        _served += chunk.length;
        _wake(_drainWaiter);
        yield chunk;
      } else if (_upstreamDone) {
        return;
      } else {
        final waiter = _dataWaiter = Completer<void>();
        await waiter.future;
      }
    }
  }

  /// One read at the served position. Returns null when the spool was
  /// cancelled during the read, and finishes the cleanup the cancel had to
  /// leave: closing a handle while a read is pending throws.
  Future<Uint8List?> _read(int length) async {
    _readerBusy = true;
    final Uint8List chunk;
    try {
      await _reader.setPosition(_served);
      chunk = await _reader.read(length);
    } finally {
      _readerBusy = false;
    }

    if (_cancelled) {
      await _closeReaderAndDelete();
      return null;
    }
    return chunk;
  }

  @override
  Future<void> cancel() => _cancelling ??= _cancel();

  Future<void> _cancel() async {
    _cancelled = true;
    _upstream.cancel();
    _wake(_dataWaiter);
    _wake(_drainWaiter);

    await _pumpDone.future;
    await _writer.close();
    if (!_readerBusy) await _closeReaderAndDelete();
  }

  Future<void> _closeReaderAndDelete() async {
    if (_readerClosed) return;
    _readerClosed = true;
    await _reader.close();
    await _deleteQuietly(file);
  }

  static void _wake(Completer<void>? waiter) {
    if (waiter != null && !waiter.isCompleted) waiter.complete();
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      await file.delete();
    } on FileSystemException catch (_) {
      // Already gone.
    }
  }

  static String _uniqueName() => '${DateTime.now().microsecondsSinceEpoch}-'
      '${_random.nextInt(1 << 32).toRadixString(16)}';
}
