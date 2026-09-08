import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/storage/hive_box_migration.dart';

/// Hive names a box's files `<lowercased name>.hive` and `<lowercased
/// name>.lock`, so these helpers mirror that rather than the declared casing.
File _hive(Directory dir, String box) =>
    File('${dir.path}${Platform.pathSeparator}${box.toLowerCase()}.hive');

File _lock(Directory dir, String box) =>
    File('${dir.path}${Platform.pathSeparator}${box.toLowerCase()}.lock');

void main() {
  late Directory from;
  late Directory to;

  setUp(() async {
    from = await Directory.systemTemp.createTemp('mydia_docs_');
    to = await Directory.systemTemp.createTemp('mydia_support_');
  });

  tearDown(() async {
    for (final dir in [from, to]) {
      if (dir.existsSync()) await dir.delete(recursive: true);
    }
  });

  group('migrateHiveBoxes', () {
    test('moves a box data file and drops the lock file behind it', () async {
      await _hive(from, 'playback_progress').writeAsString('records');
      await _lock(from, 'playback_progress').writeAsString('');

      await migrateHiveBoxes(from: from.path, to: to.path);

      expect(await _hive(to, 'playback_progress').readAsString(), 'records');
      expect(_hive(from, 'playback_progress').existsSync(), isFalse);
      expect(_lock(from, 'playback_progress').existsSync(), isFalse);
    });

    test('lowercases the box name the way Hive does', () async {
      await _hive(from, 'graphqlClientStore').writeAsString('cache');

      await migrateHiveBoxes(from: from.path, to: to.path);

      expect(
        File('${to.path}${Platform.pathSeparator}graphqlclientstore.hive')
            .existsSync(),
        isTrue,
      );
    });

    test('leaves a box that already exists at the destination alone', () async {
      await _hive(from, 'cast_session').writeAsString('old');
      await _hive(to, 'cast_session').writeAsString('current');

      await migrateHiveBoxes(from: from.path, to: to.path);

      expect(await _hive(to, 'cast_session').readAsString(), 'current');
      expect(_hive(from, 'cast_session').existsSync(), isTrue);
    });

    test('removes an orphan lock left by a box that was never written',
        () async {
      await _lock(from, 'sidebar_layout').writeAsString('');

      await migrateHiveBoxes(from: from.path, to: to.path);

      expect(_lock(from, 'sidebar_layout').existsSync(), isFalse);
    });

    test('never touches files it was not asked to move', () async {
      final unrelated = File('${from.path}${Platform.pathSeparator}notes.txt');
      await unrelated.writeAsString('a real document');
      // Another Flutter app's box, sharing the same Documents folder.
      final foreign =
          File('${from.path}${Platform.pathSeparator}someotherapp.hive');
      await foreign.writeAsString('not ours');

      await migrateHiveBoxes(from: from.path, to: to.path);

      expect(await unrelated.readAsString(), 'a real document');
      expect(await foreign.readAsString(), 'not ours');
    });

    test('is a no-op when the two paths are the same', () async {
      await _hive(from, 'window_geometry').writeAsString('geometry');

      await migrateHiveBoxes(
        from: from.path,
        to: '${from.path}${Platform.pathSeparator}',
      );

      expect(await _hive(from, 'window_geometry').readAsString(), 'geometry');
    });

    test('is a no-op when the source directory does not exist', () async {
      final missing = '${from.path}${Platform.pathSeparator}gone';

      await expectLater(
        migrateHiveBoxes(from: missing, to: to.path),
        completes,
      );
    });

    test('creates the destination directory when it is missing', () async {
      await to.delete();
      await _hive(from, 'mydia_fetch_log').writeAsString('log');

      await migrateHiveBoxes(from: from.path, to: to.path);

      expect(await _hive(to, 'mydia_fetch_log').readAsString(), 'log');
    });

    test('runs on every launch without disturbing an already-moved box',
        () async {
      await _hive(from, 'download_tasks').writeAsString('tasks');

      await migrateHiveBoxes(from: from.path, to: to.path);
      await migrateHiveBoxes(from: from.path, to: to.path);

      expect(await _hive(to, 'download_tasks').readAsString(), 'tasks');
    });

    test('leaves an open box completely alone', () async {
      // Hive holds a box's lock file open for the life of the box and deletes
      // it itself on close. Moving either file out from under it turns
      // `box.close()` into a PathNotFoundException thrown from inside Hive,
      // which is exactly what took out the E2E suite.
      await _hive(from, 'cast_session').writeAsString('live');
      await _lock(from, 'cast_session').writeAsString('held');
      await _hive(from, 'sidebar_layout').writeAsString('closed');

      await migrateHiveBoxes(
        from: from.path,
        to: to.path,
        isBoxOpen: (name) => name == 'cast_session',
      );

      expect(await _hive(from, 'cast_session').readAsString(), 'live');
      expect(_lock(from, 'cast_session').existsSync(), isTrue);
      expect(_hive(to, 'cast_session').existsSync(), isFalse);
      // The other boxes still move.
      expect(await _hive(to, 'sidebar_layout').readAsString(), 'closed');
    });

    test('asks about the declared box name, not the lowercased filename',
        () async {
      await _hive(from, 'graphqlClientStore').writeAsString('cache');
      final asked = <String>[];

      await migrateHiveBoxes(
        from: from.path,
        to: to.path,
        boxes: const ['graphqlClientStore'],
        isBoxOpen: (name) {
          asked.add(name);
          return false;
        },
      );

      expect(asked, ['graphqlClientStore']);
    });

    test('a failed cross-device copy leaves no partial box behind', () async {
      // The copy fallback runs when `rename` cannot cross a filesystem
      // boundary. A directory at the destination path forces both to fail,
      // standing in for an interrupted copy: what matters is that no
      // half-written `.hive` and no staging file survive at the destination,
      // since the next launch would read either as a completed migration.
      await _hive(from, 'playback_progress').writeAsString('records');
      await Directory(_hive(to, 'playback_progress').path).create();

      await migrateHiveBoxes(from: from.path, to: to.path);

      final leftovers = to
          .listSync()
          .map((e) => e.path.split(Platform.pathSeparator).last)
          .where((name) => name.contains('migrating'))
          .toList();
      expect(leftovers, isEmpty, reason: 'staging files must be cleaned up');
      // The source is still the only complete copy, so a later launch retries.
      expect(await _hive(from, 'playback_progress').readAsString(), 'records');
    });

    test('one unmovable box does not strand the rest', () async {
      await _hive(from, 'cast_session').writeAsString('session');
      // A directory sitting where the destination file belongs. Both the
      // rename and its copy fallback fail on it, which is the cheapest way to
      // drive a box into the per-box guard from a test.
      await Directory(_hive(to, 'cast_session').path).create();
      await _hive(from, 'downloaded_media').writeAsString('media');

      await migrateHiveBoxes(from: from.path, to: to.path);

      expect(await _hive(to, 'downloaded_media').readAsString(), 'media');
      expect(await _hive(from, 'cast_session').readAsString(), 'session');
    });
  });

  group('Hive initialization', () {
    test('nothing bypasses initAppHive', () async {
      // Both of these default their base path to the user's Documents folder,
      // which is the whole bug. `initAppHive` is the only sanctioned entry
      // point. The E2E bootstrap was missed on the first pass and only
      // surfaced as a PathNotFoundException deep inside Hive, so this looks
      // everywhere source lives rather than just `lib/`.
      //
      // Built by concatenation so this file does not match its own scan.
      final banned = ['Hive.init${'Flutter('}', 'init${'HiveForFlutter('}'];
      final offenders = <String>[];

      for (final root in ['lib', 'test', 'integration_test']) {
        await for (final entity in Directory(root).list(recursive: true)) {
          if (entity is! File || !entity.path.endsWith('.dart')) continue;
          final lines = entity.readAsLinesSync();
          for (var i = 0; i < lines.length; i++) {
            final line = lines[i];
            if (line.trimLeft().startsWith('//')) continue;
            if (banned.any(line.contains)) {
              offenders.add('${entity.path}:${i + 1}: ${line.trim()}');
            }
          }
        }
      }

      expect(
        offenders,
        isEmpty,
        reason: 'call initAppHive() from lib/core/storage/app_hive.dart '
            'instead, so boxes stay out of the user Documents folder',
      );
    });
  });

  group('kMydiaHiveBoxes', () {
    test('lists every box name declared under lib/', () async {
      // A box left out of the list keeps its file in Documents forever and
      // silently starts empty at the new path, which is invisible until a user
      // reports lost data. Cheaper to catch here, when the box is added.
      final declaration = RegExp("[Bb]oxName\\s*=\\s*'([^']+)'");
      final declared = <String, String>{};

      await for (final entity in Directory('lib').list(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        for (final match in declaration.allMatches(entity.readAsStringSync())) {
          declared[match.group(1)!] = entity.path;
        }
      }

      expect(declared, isNotEmpty, reason: 'the scan found no box names');

      final missing = {
        for (final entry in declared.entries)
          if (!kMydiaHiveBoxes.contains(entry.key)) entry.key: entry.value,
      };

      expect(
        missing,
        isEmpty,
        reason: 'add these to kMydiaHiveBoxes in '
            'lib/core/storage/hive_box_migration.dart so an upgrading install '
            'carries them over',
      );
    });
  });
}
