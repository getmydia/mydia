/// On-device probe results for files libraries, keyed by account and file and
/// valid only while the file's size and modified time are unchanged.
library;

import 'package:flutter/foundation.dart';
import 'package:hive_ce/hive.dart';

import '../../../player/mpv_probe_mapping.dart' show ProbeResult;
import '../index/index_records.dart' show IndexedFile;

class FilesMediaInfoCache {
  FilesMediaInfoCache(this._box);

  static const boxName = 'files_media_info';

  final Box<Map<dynamic, dynamic>> _box;

  static String _key(String accountId, String fileKey) => '$accountId|$fileKey';

  static String _prefix(String accountId) => '$accountId|';

  /// The stored result, or null when absent, stale (size or modified time
  /// differ) or unreadable.
  ProbeResult? get(String accountId, IndexedFile file) {
    final stored = _box.get(_key(accountId, file.key));
    if (stored == null) return null;
    try {
      if (stored['size'] != file.size ||
          stored['modified'] != file.modified.millisecondsSinceEpoch) {
        return null;
      }
      final result = stored['result'];
      if (result is! Map<dynamic, dynamic>) return null;
      return ProbeResult.fromMap(result);
    } catch (e) {
      debugPrint('[FilesMediaInfoCache] Unreadable entry ignored: $e');
      return null;
    }
  }

  Future<void> put(
    String accountId,
    IndexedFile file,
    ProbeResult result,
  ) async {
    await _box.put(_key(accountId, file.key), {
      'size': file.size,
      'modified': file.modified.millisecondsSinceEpoch,
      'result': result.toMap(),
    });
  }

  /// Drops [accountId]'s entries whose file key is not in [liveFileKeys].
  Future<void> sweep(String accountId, Set<String> liveFileKeys) async {
    final prefix = _prefix(accountId);
    await _delete(
      (k) =>
          k.startsWith(prefix) &&
          !liveFileKeys.contains(k.substring(prefix.length)),
    );
  }

  Future<void> clearAccount(String accountId) async {
    final prefix = _prefix(accountId);
    await _delete((k) => k.startsWith(prefix));
  }

  Future<void> _delete(bool Function(String key) test) async {
    final keys = _box.keys.whereType<String>().where(test).toList();
    if (keys.isNotEmpty) await _box.deleteAll(keys);
  }
}
