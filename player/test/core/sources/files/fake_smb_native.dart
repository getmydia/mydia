import 'dart:async';

import 'package:player/core/p2p/media_proxy.dart' show ProxyHeal;
import 'package:player/core/sources/files/backend/file_system_backend.dart';
import 'package:player/core/sources/files/files_account.dart';
import 'package:player/core/sources/files/smb_native.dart';

/// In-memory [SmbNative]: one tree per share, one configurable failure.
class FakeSmbNative implements SmbNative {
  final Map<String, Map<String, FileEntry>> _shares = {};

  /// Thrown by every call while set.
  BackendFailure? failure;

  /// Every [open] as (accountId, path).
  final List<(String, String)> opens = [];
  final List<String> closedAccounts = [];

  /// Every [probe]'s root.
  final List<String> probes = [];

  /// Every [probe]'s target and credentials.
  final List<(SmbTarget, SmbCredentials)> probeLogins = [];

  /// Returned by [healListener].
  ProxyHeal healResult = ProxyHeal.healthy;

  final _heals = StreamController<ProxyHeal>.broadcast();

  static String _parent(String path) {
    final i = path.lastIndexOf('/');
    return i <= 0 ? '/' : path.substring(0, i);
  }

  void addDir(String share, String path) {
    final tree = _shares.putIfAbsent(share, () => {});
    var p = path;
    while (p != '/' && !tree.containsKey(p)) {
      tree[p] = _entry(p, isDir: true, size: 0);
      p = _parent(p);
    }
  }

  void addFile(String share, String path, {int size = 1}) {
    addDir(share, _parent(path));
    _shares[share]![path] = _entry(path, isDir: false, size: size);
  }

  FileEntry _entry(String path, {required bool isDir, required int size}) =>
      FileEntry(
        path: path,
        name: path.substring(path.lastIndexOf('/') + 1),
        isDir: isDir,
        size: size,
        modified: DateTime.utc(2024),
      );

  void emitHeal(ProxyHeal heal) => _heals.add(heal);

  void _check() {
    final f = failure;
    if (f != null) throw f;
  }

  @override
  Future<List<FileEntry>> list(
      SmbTarget t, SmbCredentials c, String dir) async {
    _check();
    final tree = _shares[t.share] ?? {};
    if (dir != '/' && tree[dir]?.isDir != true) {
      throw BackendNotFound(dir);
    }
    return [
      for (final e in tree.values)
        if (_parent(e.path) == dir) e,
    ];
  }

  @override
  Future<FileEntry?> stat(SmbTarget t, SmbCredentials c, String path) async {
    _check();
    return _shares[t.share]?[path];
  }

  @override
  Future<void> probe(SmbTarget t, SmbCredentials c, String root) async {
    probes.add(root);
    probeLogins.add((t, c));
    _check();
    await list(t, c, root);
  }

  @override
  Future<List<String>> listShares(
      String host, int port, SmbCredentials c) async {
    _check();
    return _shares.keys.toList();
  }

  @override
  Future<String> open(
    String accountId,
    SmbTarget t,
    SmbCredentials c,
    String path,
  ) async {
    _check();
    opens.add((accountId, path));
    return 'http://127.0.0.1:1/smb/${opens.length - 1}';
  }

  @override
  Future<void> closeAccount(String accountId) async {
    _check();
    closedAccounts.add(accountId);
  }

  /// Like [FfiSmbNative]: a result other than healthy is also emitted on
  /// [heals].
  @override
  Future<ProxyHeal> healListener() async {
    _check();
    if (healResult != ProxyHeal.healthy) _heals.add(healResult);
    return healResult;
  }

  @override
  Stream<ProxyHeal> get heals => _heals.stream;
}
