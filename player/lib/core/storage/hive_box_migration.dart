/// Moving Hive boxes out of the directory the app used to keep them in.
///
/// Until this landed, every Hive box was opened under
/// `getApplicationDocumentsDirectory()` with no subdirectory, because both
/// `Hive.initFlutter()` and graphql_flutter's `initHiveForFlutter()` default
/// their base path to exactly that. On desktop that is the user's real
/// Documents folder, so an install scattered thirty loose `.hive`/`.lock`
/// files across it. On Windows it is worse than untidy: Documents is normally
/// redirected into OneDrive, which then syncs live database files mid-write.
///
/// [migrateHiveBoxes] moves an existing install's boxes to their new home on
/// first launch, so nobody loses playback progress, window geometry or -- the
/// one that would really hurt -- the `downloaded_media` records that point at
/// media files already on disk.
library;

import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

/// Every Hive box Mydia Player opens, by the name passed to `openBox`.
///
/// Hive derives a box's filenames from a lowercased box name (`<name>.hive`
/// and `<name>.lock`, see `hive_ce`'s `BackendManager`), which is why
/// `graphqlClientStore` is listed in its declared casing and lowercased at
/// use. A box missing from this list keeps its old file in Documents forever
/// and silently starts empty in the new location, so
/// `hive_box_migration_test.dart` asserts this list against the box-name
/// constants declared across `lib/`.
const kMydiaHiveBoxes = <String>[
  // graphql_flutter's normalized cache. `HiveStore.defaultBoxName`, spelled
  // out rather than imported so this list stays a plain data declaration.
  'graphqlClientStore',
  'mydia_fetch_log',
  'window_geometry',
  'sidebar_layout',
  'playback_progress',
  'cast_session',
  'subtitle_search_languages',
  'remote_control_settings',
  'update_dismissals',
  'compatibility_dismissals',
  'download_tasks',
  'downloaded_media',
  'download_settings',
  'storage_settings',
  'collection_sync',
];

/// Moves each of [boxes] from [from] to [to], best-effort.
///
/// Never throws. This runs on the startup path ahead of `Hive.init`, and a box
/// that cannot be moved must cost that box its history, never the launch:
/// Hive simply creates a fresh empty box at the new path. Each box is isolated
/// in its own guard so one unreadable file cannot strand the other fourteen.
///
/// Safe to run on every launch. Once a box has moved there is nothing left at
/// [from] to find, and a box whose data file already exists at [to] is left
/// strictly alone rather than overwritten.
/// [isBoxOpen] reports whether a box is currently open, and any box it names
/// is skipped entirely. Moving a box's files while Hive holds them is not
/// survivable: Hive keeps the lock file open for the life of the box and
/// deletes it itself on close, so deleting it first makes `box.close()` throw
/// `PathNotFoundException` from inside Hive, far from here. Callers pass
/// `Hive.isBoxOpen`; the default assumes nothing is open, which is what makes
/// this function testable without a Hive instance.
Future<void> migrateHiveBoxes({
  required String from,
  required String to,
  Iterable<String> boxes = kMydiaHiveBoxes,
  bool Function(String name)? isBoxOpen,
}) async {
  if (_normalize(from) == _normalize(to)) return;

  try {
    if (!Directory(from).existsSync()) return;
    await Directory(to).create(recursive: true);
  } catch (e) {
    debugPrint('[Hive] Cannot prepare box migration $from -> $to: $e');
    return;
  }

  for (final box in boxes) {
    if (isBoxOpen != null && isBoxOpen(box)) {
      debugPrint('[Hive] Box "$box" is already open; leaving it where it is');
      continue;
    }
    try {
      await _migrateBox(from, to, box.toLowerCase());
    } catch (e) {
      debugPrint('[Hive] Failed to migrate box "$box": $e');
    }
  }
}

Future<void> _migrateBox(String from, String to, String name) async {
  final source = File(_join(from, '$name.hive'));
  final destination = File(_join(to, '$name.hive'));

  if (source.existsSync()) {
    // A box already at the destination is the live one. Leaving the whole
    // pair behind is the conservative read of an ambiguous state -- it costs
    // an install that downgraded and re-upgraded a tidy Documents folder,
    // where overwriting would cost it the newer data.
    if (destination.existsSync()) return;
    await _move(source, destination);
  }

  // The lock file is a mutual-exclusion artifact Hive recreates whenever it
  // opens the box. It holds no records, so it is deleted rather than moved.
  // That is also what clears the last of the litter for a box that was only
  // ever opened and never written, which leaves a `.lock` and no `.hive`.
  final lock = File(_join(from, '$name.lock'));
  if (lock.existsSync()) {
    try {
      await lock.delete();
    } catch (e) {
      // On Windows a lock file another process still holds open cannot be
      // deleted. Nothing is lost by leaving it.
      debugPrint('[Hive] Could not remove stale lock for "$name": $e');
    }
  }
}

Future<void> _move(File source, File destination) async {
  try {
    await source.rename(destination.path);
    return;
  } on FileSystemException {
    // `rename` cannot cross a filesystem boundary, and these two paths
    // routinely sit on different ones -- a Documents folder redirected to
    // another volume, or to a OneDrive reparse point.
  }

  // Copy through a staging file in the destination directory rather than
  // straight onto `destination`. `File.copy` promises no atomicity, so an
  // interrupted copy would leave a truncated `.hive` at the destination while
  // the source is still intact -- and the next launch reads that as a
  // completed migration, because [_migrateBox] treats any existing
  // destination as authoritative. Hive would then open the fragment and its
  // crash recovery would accept it as a short box, silently losing whatever
  // had not been written. Renaming within one directory is atomic, so the
  // destination only ever appears complete.
  //
  // The pid keeps two instances racing this from writing each other's
  // staging file. A hard kill can strand one, which is inert: it lives in the
  // app's own support directory and nothing but this function looks for it.
  final staging = File('${destination.path}.$pid.migrating');
  try {
    await source.copy(staging.path);
    await staging.rename(destination.path);
    await source.delete();
  } catch (_) {
    if (staging.existsSync()) {
      try {
        await staging.delete();
      } catch (e) {
        debugPrint('[Hive] Could not clean up ${staging.path}: $e');
      }
    }
    rethrow;
  }
}

String _join(String directory, String name) =>
    '${_normalize(directory)}${Platform.pathSeparator}$name';

/// Strips trailing separators so `C:\Users\a\Documents\` and
/// `C:\Users\a\Documents` compare equal and join identically.
String _normalize(String path) {
  var end = path.length;
  while (end > 1 && path[end - 1] == Platform.pathSeparator) {
    end--;
  }
  return path.substring(0, end);
}
