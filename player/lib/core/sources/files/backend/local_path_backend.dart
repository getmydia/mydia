import 'dart:io';

import 'file_system_backend.dart';

/// Reads media straight from a folder on this device.
class LocalPathBackend implements FileSystemBackend {
  /// [root], when given, is the folder [probe] checks.
  LocalPathBackend({String? root}) : _root = root;

  final String? _root;

  @override
  Future<List<FileEntry>> list(String dir) async {
    final directory = Directory(dir);
    try {
      if (!await directory.exists()) {
        throw BackendNotFound(dir);
      }
      // Links to directories are skipped so a symlink loop cannot send a
      // recursive walk around forever; links to files resolve normally.
      final entities = await directory.list(followLinks: false).toList();
      final entries = <FileEntry>[];
      for (final entity in entities) {
        if (entity is Link && await FileSystemEntity.isDirectory(entity.path)) {
          continue;
        }
        final entry = await _entry(entity.path);
        if (entry != null) entries.add(entry);
      }
      return entries;
    } on FileSystemException catch (e) {
      throw _map(e, dir);
    }
  }

  @override
  Future<FileEntry?> stat(String path) async {
    try {
      return await _entry(path);
    } on FileSystemException catch (e) {
      throw _map(e, path);
    }
  }

  @override
  Future<PlayableFile> playable(String path) async => PlayableFile(url: path);

  @override
  Future<void> probe() async {
    final root = _root;
    if (root == null) return;
    try {
      if (!await Directory(root).exists()) {
        throw BackendUnreachable('$root does not exist');
      }
      await Directory(root).list().isEmpty;
    } on FileSystemException catch (e) {
      throw _map(e, root, missing: const BackendUnreachable());
    }
  }

  Future<FileEntry?> _entry(String path) async {
    final stat = await FileStat.stat(path);
    if (stat.type == FileSystemEntityType.notFound) return null;
    final isDir = stat.type == FileSystemEntityType.directory;
    final segments = path.split(Platform.pathSeparator)
      ..removeWhere((s) => s.isEmpty);
    return FileEntry(
      path: path,
      name: segments.isEmpty ? path : segments.last,
      isDir: isDir,
      size: isDir ? 0 : stat.size,
      modified: stat.modified,
    );
  }

  BackendFailure _map(
    FileSystemException e,
    String path, {
    BackendFailure? missing,
  }) {
    final code = e.osError?.errorCode;
    final text = '${e.message} ${e.osError?.message ?? ''}'.toLowerCase();
    if (code == 13 || code == 1 || text.contains('permission denied')) {
      return BackendPermissionLost(path);
    }
    if (code == 2 || text.contains('no such file')) {
      return missing ?? BackendNotFound(path);
    }
    return BackendUnreachable('$path: ${e.message}');
  }
}
