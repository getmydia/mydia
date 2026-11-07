import 'dart:io';

import 'package:flutter/foundation.dart';

import 'file_system_backend.dart';

/// [path] with `/` for a separator. The scanner, the index and the folder
/// listing all split on `/`; Windows hands back `\`, and its file APIs
/// accept `/` just as well. Elsewhere a `\` is an ordinary character of a
/// file name, so it is left alone.
String portableLocalPath(String path, {bool? windows}) =>
    (windows ?? Platform.isWindows) ? path.replaceAll(r'\', '/') : path;

/// What a failed local file operation means for the library. [code] is the
/// OS error number, whose meaning differs by platform: on Windows 5 is
/// ERROR_ACCESS_DENIED and 2 and 3 are file and path not found, while on
/// POSIX 13 (EACCES) and 1 (EPERM) refuse access and 2 (ENOENT) is missing.
BackendFailure mapLocalFailure(
  int? code,
  String message,
  String path, {
  BackendFailure? missing,
  bool? windows,
}) {
  final onWindows = windows ?? Platform.isWindows;
  final text = message.toLowerCase();
  final denied = onWindows ? code == 5 : (code == 13 || code == 1);
  if (denied ||
      text.contains('permission denied') ||
      text.contains('access is denied')) {
    return BackendPermissionLost(path);
  }
  final gone = onWindows ? (code == 2 || code == 3) : code == 2;
  if (gone ||
      text.contains('no such file') ||
      text.contains('cannot find the')) {
    return missing ?? BackendNotFound(path);
  }
  return BackendUnreachable('$path: $message');
}

/// Reads media straight from a folder on this device. Every path it returns
/// uses `/` (see [portableLocalPath]).
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
      final entities = await directory.list(followLinks: false).toList();
      final entries = <FileEntry>[];
      for (final entity in entities) {
        // Links are followed, to directories too: each directory carries its
        // resolved path as [FileEntry.identity], so a walk visits it once
        // and a symlink loop ends.
        try {
          final entry = await _entry(entity.path);
          if (entry != null) entries.add(entry);
        } on FileSystemException catch (e) {
          debugPrint('[LocalPathBackend] Skipping ${entity.path}: $e');
        }
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

  /// Throws [FileSystemException] when a directory's link cannot be
  /// resolved.
  Future<FileEntry?> _entry(String rawPath) async {
    final path = portableLocalPath(rawPath);
    final stat = await FileStat.stat(rawPath);
    if (stat.type == FileSystemEntityType.notFound) return null;
    final isDir = stat.type == FileSystemEntityType.directory;
    final segments = path.split('/')..removeWhere((s) => s.isEmpty);
    return FileEntry(
      path: path,
      name: segments.isEmpty ? path : segments.last,
      isDir: isDir,
      size: isDir ? 0 : stat.size,
      modified: stat.modified,
      identity: isDir
          ? portableLocalPath(await Directory(rawPath).resolveSymbolicLinks())
          : null,
    );
  }

  BackendFailure _map(
    FileSystemException e,
    String path, {
    BackendFailure? missing,
  }) =>
      mapLocalFailure(
        e.osError?.errorCode,
        '${e.message} ${e.osError?.message ?? ''}',
        path,
        missing: missing,
      );
}
