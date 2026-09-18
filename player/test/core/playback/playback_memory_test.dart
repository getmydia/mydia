import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:player/core/playback/link_path.dart';
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

      test('a stall is remembered per server and per path', () async {
        await memory.recordStall(server, LinkPath.relay, 6000, now: now);
        final stall = memory.recentStall(server, LinkPath.relay, now: now);
        expect(stall?.ceilingKbps, 6000);
        expect(stall?.at.isAtSameMomentAs(now), isTrue);
        expect(memory.recentStall(server, LinkPath.direct, now: now), isNull);
        expect(
          memory.recentStall('https://other.example', LinkPath.relay, now: now),
          isNull,
        );
      });

      test('a stall lapses after an hour', () async {
        await memory.recordStall(server, LinkPath.http, 6000, now: now);
        final justBefore =
            now.add(kStallMemoryTtl).subtract(const Duration(seconds: 1));
        expect(
          memory.recentStall(server, LinkPath.http, now: justBefore),
          isNotNull,
        );
        expect(
          memory.recentStall(server, LinkPath.http,
              now: now.add(kStallMemoryTtl)),
          isNull,
        );
      });

      test('a newer stall on the same path replaces the older one', () async {
        await memory.recordStall(server, LinkPath.relay, 6000, now: now);
        final later = now.add(const Duration(minutes: 5));
        await memory.recordStall(server, LinkPath.relay, 9000, now: later);
        expect(
          memory.recentStall(server, LinkPath.relay, now: later)?.ceilingKbps,
          9000,
        );
      });

      test('recording a stall keeps the failures already remembered', () async {
        await memory.recordFailure(server, key, FailureReason.decodeFailed,
            now: now);
        await memory.recordStall(server, LinkPath.http, 6000, now: now);
        expect(memory.failuresFor(server, now: now), {key});
      });
    });
  }

  test('HivePlaybackMemory survives a malformed record', () async {
    final box =
        await Hive.openBox<Map>('playback_memory_bad', bytes: Uint8List(0));
    await box.put(server, {'failures': 'not a map', 'stalls': 'nope'});
    final memory = HivePlaybackMemory(box);
    expect(memory.failuresFor(server, now: now), isEmpty);
    expect(memory.recentStall(server, LinkPath.http, now: now), isNull);
  });

  test('HivePlaybackMemory skips malformed stall entries', () async {
    final box = await Hive.openBox<Map>(
      'playback_memory_bad_stalls',
      bytes: Uint8List(0),
    );
    await box.put(server, {
      'failures': <String, dynamic>{},
      'stalls': {
        'relay': {'ceilingKbps': 'fast', 'at': now.toIso8601String()},
        'direct': 'not a map',
        'http': {'ceilingKbps': 6000, 'at': now.toIso8601String()},
      },
    });
    final memory = HivePlaybackMemory(box);
    expect(memory.recentStall(server, LinkPath.relay, now: now), isNull);
    expect(memory.recentStall(server, LinkPath.direct, now: now), isNull);
    expect(
      memory.recentStall(server, LinkPath.http, now: now)?.ceilingKbps,
      6000,
    );
  });

  test('HivePlaybackMemory drops a legacy throughput estimate on write',
      () async {
    final box = await Hive.openBox<Map>(
      'playback_memory_legacy_throughput',
      bytes: Uint8List(0),
    );
    await box.put(server, {
      'failures': <String, dynamic>{},
      'throughputKbps': 8000,
    });
    final memory = HivePlaybackMemory(box);
    expect(memory.recentStall(server, LinkPath.http, now: now), isNull);

    await memory.recordStall(server, LinkPath.http, 6000, now: now);

    expect(box.get(server)!.containsKey('throughputKbps'), isFalse);
    expect(
      memory.recentStall(server, LinkPath.http, now: now)?.ceilingKbps,
      6000,
    );
  });

  test('HivePlaybackMemory survives errors reading and deleting a record',
      () async {
    final memory = HivePlaybackMemory(_UnreadableBox());

    expect(memory.failuresFor(server, now: now), isEmpty);
    expect(memory.recentStall(server, LinkPath.http, now: now), isNull);
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

  group('openPlaybackMemoryBox corruption recovery', () {
    test('recovers from a corrupt box file by deleting and recreating it',
        () async {
      final tempDir =
          await Directory.systemTemp.createTemp('hive_corrupt_test_');
      addTearDown(() async {
        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      });

      const boxName = 'corrupt_test_box';
      final boxFile = File('${tempDir.path}/$boxName.hive');
      await boxFile.writeAsBytes([1, 2, 3, 4, 58, 99, 100, 255]);

      final box = await openPlaybackMemoryBox(
        boxName: boxName,
        path: tempDir.path,
      );
      addTearDown(box.close);

      expect(box.isOpen, isTrue);
      expect(box.isEmpty, isTrue);

      await box.put('server_1', {'key': 'val'});
      expect(box.get('server_1'), {'key': 'val'});
    });

    test(
        'playback memory provider resolves to HivePlaybackMemory after recovery',
        () async {
      final tempDir =
          await Directory.systemTemp.createTemp('hive_provider_test_');
      addTearDown(() async {
        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      });

      const boxName = 'corrupt_provider_box';
      final boxFile = File('${tempDir.path}/$boxName.hive');
      await boxFile.writeAsBytes([1, 2, 3, 4, 58, 99, 100, 255]);

      final container = ProviderContainer(overrides: [
        playbackMemoryBoxProvider.overrideWith(
          (ref) => openPlaybackMemoryBox(boxName: boxName, path: tempDir.path),
        ),
      ]);
      addTearDown(container.dispose);

      final memory = await container.read(playbackMemoryProvider.future);
      expect(memory, isA<HivePlaybackMemory>());
    });

    test('isBoxCorruptionError identifies corruption vs non-corruption errors',
        () {
      expect(
        isBoxCorruptionError(const FileSystemException('Permission denied')),
        isFalse,
      );
      expect(
        isBoxCorruptionError(HiveError('The box "foo" is already open')),
        isFalse,
      );
      expect(
        isBoxCorruptionError(HiveError('Hive not initialized')),
        isFalse,
      );
      expect(
        isBoxCorruptionError(HiveError('unknown typeId: 58')),
        isTrue,
      );
      expect(
        isBoxCorruptionError(HiveError('Wrong checksum in file')),
        isTrue,
      );
      expect(
        isBoxCorruptionError(HiveError('Box file is corrupted')),
        isTrue,
      );
      expect(
        isBoxCorruptionError(const FormatException('Bad frame format')),
        isTrue,
      );
      expect(
        isBoxCorruptionError(RangeError('Index out of range')),
        isTrue,
      );
    });

    test('rethrows non-corruption open failure without deleting box file',
        () async {
      final tempDir =
          await Directory.systemTemp.createTemp('hive_non_corrupt_test_');
      addTearDown(() async {
        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      });

      const boxName = 'non_corrupt_box';
      final box = await openPlaybackMemoryBox(
        boxName: boxName,
        path: tempDir.path,
      );
      addTearDown(box.close);

      // Attempting to open the same box with a different type param fails with
      // "already open and of type ...", which is not a corruption error.
      expect(
        () => Hive.openBox<String>(boxName, path: tempDir.path),
        throwsA(isA<HiveError>()),
      );

      final boxFile = File('${tempDir.path}/$boxName.hive');
      expect(boxFile.existsSync(), isTrue);
    });
  });
}
