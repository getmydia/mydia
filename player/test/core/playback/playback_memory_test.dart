import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:player/core/playback/playback_memory.dart';
import 'package:player/core/playback/playback_plan.dart';
import 'package:player/core/playback/playback_memory_providers.dart';

class _UnreadableBox extends Fake implements Box<Map> {
  @override
  Map? get(dynamic key, {Map? defaultValue}) =>
      throw StateError('corrupt record');

  @override
  Future<void> delete(dynamic key) => Future<void>.error(
        StateError('could not delete corrupt record'),
      );
}

void main() {
  const server = 'https://mydia.example';
  final now = DateTime.utc(2026, 9, 8, 12);
  const key = FailureKey(videoCodec: 'hvc1.2.4.L120.B0', heightBucket: 2160);

  group('FailureKey', () {
    test('derives from a file shape', () {
      const shape = FileShape(videoCodec: 'av01.0.08M.10', heightBucket: 1080);
      final derived = FailureKey.fromShape(shape);
      expect(
        derived,
        const FailureKey(videoCodec: 'av01.0.08M.10', heightBucket: 1080),
      );
      expect(derived.storageKey, 'av01.0.08M.10|1080');
    });

    test('round-trips through its storage key', () {
      expect(FailureKey.parse(key.storageKey), key);
      expect(FailureKey.parse('garbage'), isNull);
    });
  });

  // A fresh box name per open: `Hive.openBox` hands back an already-open box
  // of the same name, which would leak state between tests.
  var boxes = 0;

  for (final (label, open) in <(String, Future<PlaybackMemory> Function())>[
    ('InMemoryPlaybackMemory', () async => InMemoryPlaybackMemory()),
    (
      'HivePlaybackMemory',
      () async => HivePlaybackMemory(
            await Hive.openBox<Map>(
              'playback_memory_test_${boxes++}',
              bytes: Uint8List(0),
            ),
          ),
    ),
  ]) {
    group(label, () {
      late PlaybackMemory memory;

      setUp(() async => memory = await open());

      test('a recorded failure is remembered for this server only', () async {
        await memory.recordFailure(server, key, FailureReason.decodeTooSlow,
            now: now);
        expect(memory.failuresFor(server, now: now), {key});
        expect(memory.failuresFor('https://other.example', now: now), isEmpty);
      });

      test('a failure expires after 14 days', () async {
        await memory.recordFailure(server, key, FailureReason.decodeFailed,
            now: now);
        final later =
            now.add(kFailureMemoryTtl).add(const Duration(seconds: 1));
        expect(memory.failuresFor(server, now: later), isEmpty);
        expect(memory.failuresFor(server, now: now.add(kFailureMemoryTtl)),
            isEmpty);
        final justBefore =
            now.add(kFailureMemoryTtl).subtract(const Duration(seconds: 1));
        expect(memory.failuresFor(server, now: justBefore), {key});
      });

      test('throughput is an EWMA with alpha 0.3, seeded by the first sample',
          () async {
        expect(memory.throughputKbps(server), isNull);
        await memory.observeThroughput(server, 10000);
        expect(memory.throughputKbps(server), 10000);
        await memory.observeThroughput(server, 20000);
        // 0.3 * 20000 + 0.7 * 10000
        expect(memory.throughputKbps(server), 13000);
      });

      test('a bound only ever lowers the estimate', () async {
        await memory.observeThroughput(server, 10000);
        await memory.boundThroughput(server, 12000);
        expect(memory.throughputKbps(server), 10000);
        await memory.boundThroughput(server, 3600);
        expect(memory.throughputKbps(server), 3600);
      });

      test('a bound on an unknown server records it outright', () async {
        await memory.boundThroughput(server, 3600);
        expect(memory.throughputKbps(server), 3600);
      });

      test('clear forgets everything', () async {
        await memory.recordFailure(server, key, FailureReason.decodeFailed,
            now: now);
        await memory.observeThroughput(server, 5000);
        await memory.clear();
        expect(memory.failuresFor(server, now: now), isEmpty);
        expect(memory.throughputKbps(server), isNull);
      });
    });
  }

  test('HivePlaybackMemory survives a malformed record', () async {
    final box =
        await Hive.openBox<Map>('playback_memory_bad', bytes: Uint8List(0));
    await box.put(server, {'failures': 'not a map', 'throughputKbps': 'nope'});
    final memory = HivePlaybackMemory(box);
    expect(memory.failuresFor(server, now: now), isEmpty);
    expect(memory.throughputKbps(server), isNull);
  });

  test('HivePlaybackMemory survives errors reading and deleting a record',
      () async {
    final memory = HivePlaybackMemory(_UnreadableBox());

    expect(memory.failuresFor(server, now: now), isEmpty);
    expect(memory.throughputKbps(server), isNull);
    await pumpEventQueue();
  });

  test('playback memory provider falls back when its box will not open',
      () async {
    final container = ProviderContainer(overrides: [
      playbackMemoryBoxProvider.overrideWith(
        (ref) async => throw StateError('box unavailable'),
      ),
    ]);
    addTearDown(container.dispose);

    final memory = await container.read(playbackMemoryProvider.future);

    expect(memory, isA<InMemoryPlaybackMemory>());
  });
}
