/// A files backend over an SMB share, through [SmbNative].
library;

import 'package:flutter/foundation.dart';

import '../files_account.dart';
import '../smb_native.dart';
import 'file_system_backend.dart';

/// One share. Paths are share-relative and start with `/`; entries are
/// returned as [SmbNative] gives them.
class SmbBackend implements FileSystemBackend {
  SmbBackend({
    required this.native,
    required this.accountId,
    required this.target,
    required this.credentials,
  });

  final SmbNative native;
  final String accountId;
  final SmbTarget target;
  final SmbCredentials credentials;

  @override
  Future<List<FileEntry>> list(String dir) =>
      native.list(target, credentials, dir);

  @override
  Future<FileEntry?> stat(String path) =>
      native.stat(target, credentials, path);

  @override
  Future<PlayableFile> playable(String path) async => PlayableFile(
      url: await native.open(accountId, target, credentials, path));

  @override
  Future<void> probe() => native.probe(target, credentials, '/');
}

/// An [SmbBackend] built on first use from the stored credentials. A missing
/// or unreadable credential is a refused one, and a refused call drops the
/// built backend, so the next call reads the credentials again (after the
/// viewer signs in anew).
class LazySmbBackend implements FileSystemBackend {
  LazySmbBackend({
    required this.native,
    required this.accountId,
    required this.target,
    required this.credentials,
  });

  final SmbNative native;
  final String accountId;
  final SmbTarget target;
  final Future<String?> Function() credentials;
  Future<SmbBackend>? _backend;

  Future<T> _call<T>(Future<T> Function(SmbBackend b) run) async {
    final b = await _resolve();
    try {
      return await run(b);
    } on BackendUnauthorized {
      _backend = null;
      rethrow;
    }
  }

  Future<SmbBackend> _resolve() => _backend ??= _build().then(
        (b) => b,
        onError: (Object e, StackTrace st) {
          _backend = null;
          Error.throwWithStackTrace(e, st);
        },
      );

  Future<SmbBackend> _build() async {
    final stored = await credentials();
    if (stored == null) throw const BackendUnauthorized('no credentials');
    final SmbCredentials c;
    try {
      c = SmbCredentials.fromJson(stored);
    } on FormatException catch (e) {
      debugPrint('[FilesSource] Unreadable SMB credentials: $e');
      throw const BackendUnauthorized('unreadable credentials');
    }
    return SmbBackend(
        native: native, accountId: accountId, target: target, credentials: c);
  }

  @override
  Future<List<FileEntry>> list(String dir) => _call((b) => b.list(dir));

  @override
  Future<FileEntry?> stat(String path) => _call((b) => b.stat(path));

  @override
  Future<PlayableFile> playable(String path) => _call((b) => b.playable(path));

  @override
  Future<void> probe() => _call((b) => b.probe());
}
