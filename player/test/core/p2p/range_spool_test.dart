import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/p2p/disk_space.dart';
import 'package:player/core/p2p/range_spool.dart';

import 'fake_range_stream.dart';

const _plenty = DiskSpace(free: 1 << 40, total: 1 << 41);
const _smallPieces = RangeSpoolPolicy(readChunkBytes: 4096);

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('range_spool_test');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  FakeRangeStream upstreamOf(
    int totalBytes, {
    int? stallAfterBytes,
    Duration pace = Duration.zero,
  }) {
    return FakeRangeStream(
      header: fakeRangeHeader(contentLength: totalBytes),
      totalBytes: totalBytes,
      chunkBytes: 4096,
      stallAfterBytes: stallAfterBytes,
      pace: pace,
    );
  }

  Future<RangeSpool> openSpool(
    FakeRangeStream upstream, {
    DiskSpaceProbe? diskSpace,
    RangeSpoolPolicy policy = _smallPieces,
  }) async {
    final spool = await RangeSpool.open(
      upstream: upstream,
      directory: dir,
      diskSpace: diskSpace ?? (_) async => _plenty,
      policy: policy,
    );
    expect(spool, isNotNull);
    addTearDown(spool!.cancel);
    return spool;
  }

  Future<List<int>> readAll(Stream<List<int>> stream) =>
      stream.fold<List<int>>([], (all, chunk) => all..addAll(chunk));

  test('keeps downloading while nothing reads', () async {
    const total = 256 * 1024;
    final upstream = upstreamOf(total);

    final spool = await openSpool(upstream);

    await waitUntil(() => upstream.pulledBytes == total);
    await waitUntil(() => spool.file.lengthSync() == total);
    expect(spool.spooledBytes, total);
  });

  test('serves the upstream bytes in order', () async {
    const total = 300 * 1000 + 7;
    final spool = await openSpool(upstreamOf(total));

    expect(await readAll(spool.bytes()), fakeBytes(0, total));
  });

  test('waits for bytes that arrive after the reader caught up', () async {
    const total = 64 * 1024;
    final spool = await openSpool(
      upstreamOf(total, pace: const Duration(milliseconds: 5)),
    );

    expect(await readAll(spool.bytes()), fakeBytes(0, total));
  });

  test('ends short when the upstream ends early', () async {
    final upstream = FakeRangeStream(
      header: fakeRangeHeader(contentLength: 100 * 1024),
      totalBytes: 40 * 1024,
      chunkBytes: 4096,
    );
    final spool = await openSpool(upstream);

    expect(await readAll(spool.bytes()), fakeBytes(0, 40 * 1024));
  });

  group('cancel', () {
    test('cancels the upstream and deletes the file', () async {
      final upstream = upstreamOf(1 << 30, stallAfterBytes: 64 * 1024);
      final spool = await openSpool(upstream);
      await waitUntil(() => upstream.pulledBytes == 64 * 1024);

      await spool.cancel();

      expect(upstream.isCancelled, isTrue);
      expect(spool.file.existsSync(), isFalse);
    });

    test('stops a download in progress', () async {
      final upstream = upstreamOf(
        1 << 30,
        pace: const Duration(milliseconds: 1),
      );
      final spool = await openSpool(upstream);
      await waitUntil(() => upstream.pulledBytes > 16 * 1024);

      await spool.cancel();
      final pulled = upstream.pulledBytes;
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(upstream.pulledBytes, pulled);
      expect(spool.file.existsSync(), isFalse);
    });

    test('ends a reader that is waiting for data', () async {
      final spool = await openSpool(upstreamOf(1 << 30, stallAfterBytes: 0));
      final read = readAll(spool.bytes());
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await spool.cancel();

      expect(await read.timeout(const Duration(seconds: 2)), isEmpty);
      expect(spool.file.existsSync(), isFalse);
    });

    test('ends a reader paused between chunks', () async {
      final spool = await openSpool(upstreamOf(256 * 1024));
      final reader = StreamIterator(spool.bytes());
      expect(await reader.moveNext(), isTrue);

      await spool.cancel();

      expect(spool.file.existsSync(), isFalse);
      expect(await reader.moveNext(), isFalse);
    });

    test('twice is harmless', () async {
      final spool = await openSpool(upstreamOf(64 * 1024));

      await Future.wait([spool.cancel(), spool.cancel()]);
      await spool.cancel();

      expect(spool.file.existsSync(), isFalse);
    });
  });

  group('disk budget', () {
    test('does not open on a volume already inside the reserve', () async {
      final upstream = upstreamOf(1024);

      // Reserve is 10% of 1 TiB, far more than the 1 GiB free.
      final spool = await RangeSpool.open(
        upstream: upstream,
        directory: dir,
        diskSpace: (_) async => const DiskSpace(free: 1 << 30, total: 1 << 40),
      );

      expect(spool, isNull);
      expect(upstream.isCancelled, isFalse);
      expect(dir.listSync(), isEmpty);
    });

    test('does not open when space cannot be measured', () async {
      final upstream = upstreamOf(1024);

      final spool = await RangeSpool.open(
        upstream: upstream,
        directory: dir,
        diskSpace: (_) async => null,
      );

      expect(spool, isNull);
      expect(upstream.isCancelled, isFalse);
      expect(dir.listSync(), isEmpty);
    });

    test('pauses at the budget and resumes once the reader drains', () async {
      const total = 200 * 1024;
      const volume = 100 * 1024;
      final upstream = upstreamOf(total);

      // The volume holds only this spool, so free space is what it has not
      // used. The reserve is 40 KiB, leaving the spool 60 KiB; checks run
      // every 8 KiB, so it stops at the first check past 60 KiB.
      Future<DiskSpace?> probe(String path) async {
        final used = dir
            .listSync()
            .whereType<File>()
            .fold<int>(0, (sum, file) => sum + file.lengthSync());
        return DiskSpace(free: volume - used, total: volume);
      }

      final spool = await openSpool(
        upstream,
        diskSpace: probe,
        policy: const RangeSpoolPolicy(
          reserveFloorBytes: 40 * 1024,
          reserveFraction: 0,
          checkIntervalBytes: 8 * 1024,
          readChunkBytes: 4096,
        ),
      );

      await waitUntil(() => upstream.pulledBytes == 64 * 1024);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(upstream.pulledBytes, 64 * 1024);

      expect(await readAll(spool.bytes()), fakeBytes(0, total));
      expect(spool.truncations, greaterThanOrEqualTo(1));
    });
  });
}
