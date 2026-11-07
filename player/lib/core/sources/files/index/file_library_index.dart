import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_ce/hive.dart';

import 'index_records.dart';

export 'index_records.dart';

/// Stable key for a file: first 16 hex chars of SHA-256 over
/// `"$rootId/$relativePath"`.
String fileKeyFor(String rootId, String relativePath) => sha256
    .convert(utf8.encode('$rootId/$relativePath'))
    .toString()
    .substring(0, 16);

/// Local index of one account's files library, in a plain `Box<Map>`.
///
/// Keys are `<accountId>/<type>/<id>`. The account's records are read once on
/// construction; writes go through the box immediately and update the maps,
/// reads are synchronous. An unreadable record is skipped, never thrown.
class FileLibraryIndex {
  static const boxName = 'files_index';

  FileLibraryIndex(this._box, {required String accountId})
      : _prefix = '$accountId/' {
    for (final key in _box.keys) {
      if (key is! String || !key.startsWith(_prefix)) continue;
      final rest = key.substring(_prefix.length);
      final slash = rest.indexOf('/');
      if (slash < 0) continue;
      final type = rest.substring(0, slash);
      final id = rest.substring(slash + 1);
      try {
        _load(type, id, _box.get(key)!);
      } catch (e) {
        debugPrint('[FileLibraryIndex] Skipping unreadable record $key: $e');
      }
    }
  }

  final Box<Map<dynamic, dynamic>> _box;
  final String _prefix;

  final _roots = <String, LibraryRoot>{};
  final _files = <String, IndexedFile>{};
  final _groups = <String, GroupMatch>{};
  final _movies = <int, MatchedMovie>{};
  final _shows = <int, MatchedShow>{};
  final _watched = <String>{};
  DateTime? _lastScanAt;

  static const _root = 'root';
  static const _file = 'file';
  static const _group = 'group';
  static const _movie = 'movie';
  static const _show = 'show';
  static const _watchedType = 'watched';
  static const _scan = 'scan';

  String _key(String type, Object id) => '$_prefix$type/$id';

  void _load(String type, String id, Map<dynamic, dynamic> m) {
    switch (type) {
      case _root:
        _roots[id] = LibraryRoot.fromMap(m);
      case _file:
        _files[id] = IndexedFile.fromMap(m);
      case _group:
        _groups[id] = GroupMatch.fromMap(m);
      case _movie:
        _movies[int.parse(id)] = MatchedMovie.fromMap(m);
      case _show:
        _shows[int.parse(id)] = MatchedShow.fromMap(m);
      case _watchedType:
        _watched.add(id);
      case _scan:
        _lastScanAt = DateTime.fromMillisecondsSinceEpoch(m['at'] as int);
    }
  }

  List<LibraryRoot> roots() => _roots.values.toList();

  Future<void> putRoot(LibraryRoot r) async {
    _roots[r.id] = r;
    await _box.put(_key(_root, r.id), r.toMap());
  }

  /// Also removes the root's files.
  Future<void> removeRoot(String id) async {
    _roots.remove(id);
    final fileKeys = [
      for (final f in _files.values)
        if (f.rootId == id) f.key,
    ];
    await _box.delete(_key(_root, id));
    await removeFiles(fileKeys);
  }

  Map<String, IndexedFile> files() => Map.unmodifiable(_files);

  Future<void> putFiles(Iterable<IndexedFile> files) async {
    final batch = {for (final f in files) f.key: f};
    // Stored first, so a write that fails leaves memory matching the box.
    await _box.putAll({
      for (final f in batch.values) _key(_file, f.key): f.toMap(),
    });
    _files.addAll(batch);
  }

  Future<void> removeFiles(Iterable<String> keys) async {
    final list = keys.toList();
    for (final k in list) {
      _files.remove(k);
    }
    await _box.deleteAll([for (final k in list) _key(_file, k)]);
  }

  GroupMatch? group(String key) => _groups[key];

  Future<void> putGroup(GroupMatch g) async {
    _groups[g.groupKey] = g;
    await _box.put(_key(_group, g.groupKey), g.toMap());
  }

  MatchedMovie? movie(int id) => _movies[id];

  Future<void> putMovie(MatchedMovie m) async {
    _movies[m.tmdbId] = m;
    await _box.put(_key(_movie, m.tmdbId), m.toMap());
  }

  MatchedShow? show(int id) => _shows[id];

  Future<void> putShow(MatchedShow s) async {
    _shows[s.tmdbId] = s;
    await _box.put(_key(_show, s.tmdbId), s.toMap());
  }

  Set<String> watched() => Set.unmodifiable(_watched);

  Future<void> setWatched(String externalId, bool watched) async {
    if (watched) {
      _watched.add(externalId);
      await _box.put(_key(_watchedType, externalId), <String, dynamic>{});
    } else {
      _watched.remove(externalId);
      await _box.delete(_key(_watchedType, externalId));
    }
  }

  DateTime? lastScanAt() => _lastScanAt;

  Future<void> setLastScanAt(DateTime t) async {
    _lastScanAt = t;
    await _box.put(_key(_scan, 'at'), {'at': t.millisecondsSinceEpoch});
  }

  /// Removes every record of this account.
  Future<void> clear() async {
    final keys = [
      for (final k in _box.keys)
        if (k is String && k.startsWith(_prefix)) k,
    ];
    await _box.deleteAll(keys);
    _roots.clear();
    _files.clear();
    _groups.clear();
    _movies.clear();
    _shows.clear();
    _watched.clear();
    _lastScanAt = null;
  }
}
