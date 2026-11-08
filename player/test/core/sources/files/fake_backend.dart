import 'package:player/core/sources/files/backend/file_system_backend.dart';

/// In-memory [FileSystemBackend] built from absolute file path -> size.
/// Parent directories are implied. Directories listed in [failures] throw
/// the given [BackendFailure] from [list].
class FakeBackend implements FileSystemBackend {
  FakeBackend(
    Map<String, int> files, {
    Map<String, DateTime> modified = const {},
    this.probeFailure,
  })  : _sizes = Map.of(files),
        _modified = Map.of(modified);

  static final defaultModified = DateTime.fromMillisecondsSinceEpoch(
    1700000000000,
  );

  final Map<String, int> _sizes;
  final Map<String, DateTime> _modified;

  /// Directory path -> failure thrown by [list] for it.
  final Map<String, BackendFailure> failures = {};

  /// Files [list] marks [FileEntry.unreadable], as a server refusing them.
  final Set<String> unreadable = {};

  /// When set, [probe] throws it.
  BackendFailure? probeFailure;

  /// Every directory passed to [list], in order.
  final List<String> listed = [];

  void setFile(String path, int size, {DateTime? modified}) {
    _sizes[path] = size;
    if (modified != null) _modified[path] = modified;
  }

  void removeFile(String path) {
    _sizes.remove(path);
    _modified.remove(path);
  }

  DateTime _mtime(String path) => _modified[path] ?? defaultModified;

  static String _norm(String p) =>
      p.length > 1 && p.endsWith('/') ? p.substring(0, p.length - 1) : p;

  static String _name(String p) => p.substring(p.lastIndexOf('/') + 1);

  Set<String> get _dirs {
    final dirs = <String>{};
    for (final f in _sizes.keys) {
      var i = f.lastIndexOf('/');
      while (i > 0) {
        final d = f.substring(0, i);
        if (!dirs.add(d)) break;
        i = d.lastIndexOf('/');
      }
    }
    return dirs;
  }

  @override
  Future<List<FileEntry>> list(String dir) async {
    final d = _norm(dir);
    listed.add(d);
    final failure = failures[d];
    if (failure != null) throw failure;
    final prefix = d == '/' ? '/' : '$d/';
    final out = <FileEntry>[];
    for (final e in _sizes.entries) {
      if (!e.key.startsWith(prefix) ||
          e.key.substring(prefix.length).contains('/')) {
        continue;
      }
      out.add(
        FileEntry(
          path: e.key,
          name: _name(e.key),
          isDir: false,
          size: e.value,
          modified: _mtime(e.key),
          unreadable: unreadable.contains(e.key),
        ),
      );
    }
    for (final sub in _dirs) {
      if (!sub.startsWith(prefix) ||
          sub.substring(prefix.length).contains('/')) {
        continue;
      }
      out.add(
        FileEntry(
          path: sub,
          name: _name(sub),
          isDir: true,
          size: 0,
          modified: defaultModified,
        ),
      );
    }
    if (out.isEmpty && !_dirs.contains(d) && d != '/') {
      throw BackendNotFound(d);
    }
    return out;
  }

  @override
  Future<FileEntry?> stat(String path) async {
    final p = _norm(path);
    final size = _sizes[p];
    if (size != null) {
      return FileEntry(
        path: p,
        name: _name(p),
        isDir: false,
        size: size,
        modified: _mtime(p),
      );
    }
    if (_dirs.contains(p)) {
      return FileEntry(
        path: p,
        name: _name(p),
        isDir: true,
        size: 0,
        modified: defaultModified,
      );
    }
    return null;
  }

  @override
  Future<PlayableFile> playable(String path) async =>
      PlayableFile(url: 'fake://$path');

  @override
  Future<void> probe() async {
    final f = probeFailure;
    if (f != null) throw f;
  }
}
