import 'package:flutter/foundation.dart';

import '../../connection/app_foreground.dart';
import '../backend/file_system_backend.dart';
import '../index/file_library_index.dart';
import '../media_names.dart';

/// What one scan changed in the index.
class ScanDelta {
  const ScanDelta({
    this.added = const [],
    this.changed = const [],
    this.removedKeys = const [],
    this.skippedPaths = const [],
  });

  final List<IndexedFile> added;
  final List<IndexedFile> changed;
  final List<String> removedKeys;

  /// Folders and files below the root that could not be read, relative to
  /// it. What the index held for them, and under them, was left as it was.
  final List<String> skippedPaths;

  bool get isEmpty => added.isEmpty && changed.isEmpty && removedKeys.isEmpty;
}

/// Walks a [LibraryRoot] through a [FileSystemBackend], parses new and
/// changed video names, and writes the result to the [FileLibraryIndex].
class FileScanner {
  FileScanner({
    required FileSystemBackend backend,
    required MediaNames names,
    required FileLibraryIndex index,
    DateTime Function()? now,
    AppForeground? foreground,
  })  : _backend = backend,
        _names = names,
        _index = index,
        _now = now ?? DateTime.now,
        _foreground = foreground;

  /// How many times one folder is listed when each failure comes with the
  /// app having left the foreground, before the walk gives up on it.
  static const maxReadsAcrossSuspensions = 4;

  static const _batchSize = 200;
  static const videoExtensions = {
    'mkv', 'mp4', 'm4v', 'mov', 'avi', 'ts', 'm2ts', 'webm', 'wmv', 'mpg', //
    'mpeg', 'ogv',
  };
  static const subtitleExtensions = {'srt', 'ass', 'ssa', 'vtt'};
  static const _maxDepth = 32;
  static const _skippedDirs = {'@eaDir', '#recycle'};

  final FileSystemBackend _backend;
  final MediaNames _names;
  final FileLibraryIndex _index;
  final DateTime Function() _now;
  final AppForeground? _foreground;

  /// Scans [root] and writes the outcome to the index before returning.
  /// A [BackendFailure] reading the root, or the backend going unreachable,
  /// is rethrown with the index untouched; a folder below the root that
  /// cannot be read is skipped (see [_walk]). [onFolderRead] counts the
  /// folders listed so far while the tree is walked, before [onProgress]
  /// has a total to report.
  Future<ScanDelta> scan(
    LibraryRoot root, {
    void Function(int done, int total)? onProgress,
    void Function(int folders)? onFolderRead,
  }) async {
    final registered = _registered(root);
    final videos = <FileEntry>[];
    final sidecarsByDir = <String, List<FileEntry>>{};
    final skipped = [
      for (final path
          in await _walk(root.path, videos, sidecarsByDir, onFolderRead))
        _relative(root.path, path),
    ];
    bool wasSkipped(String rel) =>
        skipped.any((s) => rel == s || rel.startsWith('$s/'));

    final existing = {
      for (final f in _index.files().values)
        if (f.rootId == root.id) f.key: f,
    };

    final total = videos.length;
    var done = 0;
    final added = <IndexedFile>[];
    final changed = <IndexedFile>[];
    final seen = <String>{};

    final pending = <_Pending>[];
    for (final v in videos) {
      final rel = _relative(root.path, v.path);
      final key = fileKeyFor(root.id, rel);
      seen.add(key);
      final sidecars = _sidecarsFor(root.path, v, sidecarsByDir);
      final old = existing[key];
      if (old == null) {
        pending.add(_Pending(v, rel, key, sidecars, null));
      } else if (old.size != v.size ||
          !old.modified.isAtSameMomentAs(v.modified) ||
          old.parsedAs != root.kind) {
        pending.add(_Pending(v, rel, key, sidecars, old));
      } else if (!_sameList(old.sidecars, sidecars)) {
        changed.add(
            _build(root, _Pending(v, rel, key, sidecars, old), old.parsed));
        done++;
      } else {
        done++;
      }
    }
    onProgress?.call(done, total);

    for (var i = 0; i < pending.length; i += _batchSize) {
      final batch = pending.sublist(
        i,
        i + _batchSize > pending.length ? pending.length : i + _batchSize,
      );
      final parsed = _names.parseBatch(
        root.path,
        [for (final p in batch) p.entry.path],
        root.kind,
      );
      final byPath = {for (final p in parsed) p.path: p};
      for (final p in batch) {
        final file = _build(root, p, byPath[p.entry.path]);
        (p.old == null ? added : changed).add(file);
      }
      done += batch.length;
      onProgress?.call(done, total);
    }
    if (pending.isEmpty && total == 0) onProgress?.call(0, 0);

    // A file that could not be read, or is under a folder that could not
    // be, was not looked at, so it is kept rather than reported gone.
    final removed = [
      for (final MapEntry(key: k, value: f) in existing.entries)
        if (!seen.contains(k) && !wasSkipped(f.path)) k,
    ];

    // The root was removed while it was being walked: writing now would
    // bring its files back under a root that is gone.
    if (registered && !_registered(root)) return const ScanDelta();
    await _index.putFiles([...added, ...changed]);
    if (removed.isNotEmpty) await _index.removeFiles(removed);
    return ScanDelta(
      added: added,
      changed: changed,
      removedKeys: removed,
      skippedPaths: skipped,
    );
  }

  bool _registered(LibraryRoot root) =>
      _index.roots().any((r) => r.id == root.id);

  IndexedFile _build(LibraryRoot root, _Pending p, ParsedName? parsed) =>
      IndexedFile(
        key: p.key,
        rootId: root.id,
        path: p.relative,
        size: p.entry.size,
        modified: p.entry.modified,
        firstSeen: p.old?.firstSeen ?? _now(),
        parsed: parsed,
        sidecars: p.sidecars,
        parsedAs: root.kind,
      );

  /// Walks [start] and returns the paths below it that could not be read.
  ///
  /// A folder below the root that refuses access or vanished (`lost+found`
  /// at the top of an ext4 drive, a WebDAV folder answering 403), or an
  /// entry its listing marks [FileEntry.unreadable], is left out with what
  /// is under it, and the walk goes on: one such path must not fail every
  /// scan or ask the viewer to sign in again. The root failing, or the
  /// backend going unreachable anywhere, still ends the walk, unless the app
  /// left the foreground meanwhile (see [_list]).
  Future<List<String>> _walk(
    String start,
    List<FileEntry> videos,
    Map<String, List<FileEntry>> sidecarsByDir,
    void Function(int folders)? onFolderRead,
  ) async {
    final unreadable = <String>[];
    var foldersRead = 0;
    final stats = WalkStats();
    final clock = Stopwatch()..start();
    final queue = <(String, int)>[(start, 0)];
    // Directories are told apart by where they really are, so one reached
    // through a symbolic link as well as directly is walked once, and a
    // link back up the tree ends rather than looping to the depth cap.
    FileEntry? self;
    try {
      self = await _backend.stat(start);
    } on BackendFailure {
      // The list below throws the failure that matters.
    }
    final visited = <String>{_identity(self) ?? _trimSlash(start)};
    while (queue.isNotEmpty) {
      final (dir, depth) = queue.removeLast();
      final List<FileEntry> entries;
      try {
        entries = await _list(dir);
        onFolderRead?.call(++foldersRead);
      } on BackendFailure catch (e) {
        final belowRoot = depth > 0;
        final refusedOrGone = e is BackendPermissionLost ||
            e is BackendUnauthorized ||
            e is BackendNotFound;
        if (!belowRoot || !refusedOrGone) {
          debugPrint('[FileScanner] $start walk failed at $dir after '
              '${clock.elapsed.inSeconds}s, ${stats.summary()}: $e');
          rethrow;
        }
        debugPrint('[FileScanner] Skipping $dir: $e');
        unreadable.add(_trimSlash(dir));
        continue;
      }
      stats.folders++;
      if (depth == 0) {
        // What the root holds, as the backend handed it over: the first
        // thing to look at when a library comes up empty.
        debugPrint('[FileScanner] $start lists ${entries.length} entries: '
            '${describeEntries(entries)}');
      }
      for (final e in entries) {
        stats.count(e);
        if (e.name.startsWith('.')) continue;
        if (e.unreadable) {
          // Neither read nor descended into, and kept as indexed. Only what
          // could hold media is reported: a folder, a video, or a name with
          // no extension, which may well be a folder.
          final ext = _ext(e.name);
          if (e.isDir || ext.isEmpty || videoExtensions.contains(ext)) {
            unreadable.add(_trimSlash(e.path));
          }
          continue;
        }
        if (e.isDir) {
          if (_skippedDirs.contains(e.name) || depth >= _maxDepth) continue;
          if (visited.add(_identity(e)!)) queue.add((e.path, depth + 1));
          continue;
        }
        final ext = _ext(e.name);
        if (videoExtensions.contains(ext)) {
          videos.add(e);
        } else if (subtitleExtensions.contains(ext)) {
          sidecarsByDir.putIfAbsent(_dirOf(e.path), () => []).add(e);
        }
      }
    }
    videos.sort((a, b) => a.path.compareTo(b.path));
    debugPrint('[FileScanner] $start walked in ${clock.elapsed.inSeconds}s: '
        '${stats.summary()}, ${unreadable.length} skipped as unreadable');
    return unreadable;
  }

  /// Lists [dir]. A walk over a network share can take minutes, and on iOS
  /// leaving the app freezes it: the request in flight then fails as
  /// unreachable once the app is back. Such a failure, with the app having
  /// left during the request, waits for the foreground and lists the same
  /// folder again, so the walk goes on where it was instead of the whole
  /// root being dropped and started over from nothing. A listing is only
  /// started in the foreground: one started in the seconds iOS grants after
  /// leaving would be frozen with no departure during it to tell why.
  Future<List<FileEntry>> _list(String dir) async {
    final foreground = _foreground;
    for (var reads = 1;; reads++) {
      if (foreground != null && !foreground.foreground) {
        await foreground.whenForeground();
      }
      final departures = foreground?.departures;
      try {
        return await _backend.list(dir);
      } on BackendUnreachable catch (e) {
        if (foreground == null ||
            foreground.departures == departures ||
            reads >= maxReadsAcrossSuspensions) {
          rethrow;
        }
        debugPrint('[FileScanner] $dir cut off while the app was away '
            '($e); reading it again on return');
      }
    }
  }

  List<String> _sidecarsFor(
    String rootPath,
    FileEntry video,
    Map<String, List<FileEntry>> sidecarsByDir,
  ) {
    final candidates = sidecarsByDir[_dirOf(video.path)];
    if (candidates == null) return const [];
    final dot = video.name.lastIndexOf('.');
    final prefix = '${dot > 0 ? video.name.substring(0, dot) : video.name}.';
    return [
      for (final s in candidates)
        if (s.name.startsWith(prefix)) _relative(rootPath, s.path),
    ]..sort();
  }

  static String? _identity(FileEntry? e) =>
      e == null ? null : _trimSlash(e.identity ?? e.path);

  static String _trimSlash(String p) =>
      p.length > 1 && p.endsWith('/') ? p.substring(0, p.length - 1) : p;

  static String _ext(String name) {
    final dot = name.lastIndexOf('.');
    return dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  }

  static String _dirOf(String path) {
    final i = path.lastIndexOf('/');
    return i <= 0 ? '' : path.substring(0, i);
  }

  static String _relative(String rootPath, String path) {
    var root = rootPath;
    while (root.length > 1 && root.endsWith('/')) {
      root = root.substring(0, root.length - 1);
    }
    var rel = path.startsWith(root) ? path.substring(root.length) : path;
    while (rel.startsWith('/')) {
      rel = rel.substring(1);
    }
    return rel;
  }

  static bool _sameList(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Up to [max] of [entries] as `name/` for a folder, `name (size)` for a
/// file, with `!` after an entry the server refused, for the log.
@visibleForTesting
String describeEntries(List<FileEntry> entries, {int max = 12}) {
  final shown = [
    for (final e in entries.take(max))
      '${e.name}${e.isDir ? '/' : ' (${e.size})'}${e.unreadable ? '!' : ''}',
  ];
  final more = entries.length - shown.length;
  return [...shown, if (more > 0) '... $more more'].join(', ');
}

/// What a walk saw, for the log line that ends it: how many entries were
/// folders, videos, subtitles and other files (by extension), hidden, or
/// refused by the server.
@visibleForTesting
class WalkStats {
  var folders = 0;
  var dirs = 0;
  var videos = 0;
  var subtitles = 0;
  var hidden = 0;
  var unreadable = 0;
  final other = <String, int>{};

  void count(FileEntry e) {
    if (e.name.startsWith('.')) {
      hidden++;
    } else if (e.unreadable) {
      unreadable++;
    } else if (e.isDir) {
      dirs++;
    } else {
      final ext = FileScanner._ext(e.name);
      if (FileScanner.videoExtensions.contains(ext)) {
        videos++;
      } else if (FileScanner.subtitleExtensions.contains(ext)) {
        subtitles++;
      } else {
        final key = ext.isEmpty ? '(none)' : ext;
        other[key] = (other[key] ?? 0) + 1;
      }
    }
  }

  String summary() {
    final top = (other.entries.toList()
          ..sort((a, b) => b.value.compareTo(a.value)))
        .take(6)
        .map((e) => '${e.key} ${e.value}')
        .join(', ');
    final others = other.values.fold(0, (a, b) => a + b);
    return '$folders folders read, $dirs subfolders, $videos videos, '
        '$subtitles subtitles, $others other files'
        '${top.isEmpty ? '' : ' [$top]'}, $hidden hidden, '
        '$unreadable refused';
  }
}

class _Pending {
  const _Pending(this.entry, this.relative, this.key, this.sidecars, this.old);

  final FileEntry entry;
  final String relative;
  final String key;
  final List<String> sidecars;
  final IndexedFile? old;
}
