import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../native/smb.dart' as native;
import '../../p2p/media_proxy.dart' show ProxyHeal;
import 'backend/file_system_backend.dart';
import 'files_account.dart';

/// [BackendUnreachable.message] of a server that speaks SMB1 only.
const kSmb1OnlyReason = 'smb1-only';

/// Where a share lives.
class SmbTarget {
  const SmbTarget(
      {required this.host, required this.port, required this.share});

  final String host;
  final int port;
  final String share;
}

/// The SMB client and its loopback range server, in the Rust core.
///
/// Paths are share-relative, `/`-separated, and start with `/`. Every method
/// throws a [BackendFailure].
abstract interface class SmbNative {
  Future<List<FileEntry>> list(SmbTarget t, SmbCredentials c, String dir);

  /// Null when [path] does not exist.
  Future<FileEntry?> stat(SmbTarget t, SmbCredentials c, String path);

  /// Succeeds when the share is reachable and [root] is a readable directory.
  Future<void> probe(SmbTarget t, SmbCredentials c, String root);

  Future<List<String>> listShares(String host, int port, SmbCredentials c);

  /// A loopback URL the player can stream [path] from.
  Future<String> open(
    String accountId,
    SmbTarget t,
    SmbCredentials c,
    String path,
  );

  /// Forgets the account's playback URLs and closes their connections.
  Future<void> closeAccount(String accountId);

  Future<ProxyHeal> healListener();

  /// Every [healListener] result other than [ProxyHeal.healthy].
  Stream<ProxyHeal> get heals;
}

class FfiSmbNative implements SmbNative {
  FfiSmbNative() : _override = null;

  /// Runs [invoke] in place of every native call, so error mapping can be
  /// tested without the native library.
  FfiSmbNative.forTest(Future<dynamic> Function() invoke) : _override = invoke;

  final Future<dynamic> Function()? _override;
  final _heals = StreamController<ProxyHeal>.broadcast();

  Future<T> _run<T>(Future<T> Function() call) async {
    try {
      final override = _override;
      return override != null ? await override() as T : await call();
    } on native.FfiSmbError catch (e) {
      throw _mapError(e);
    } on BackendFailure {
      rethrow;
    } catch (e) {
      // A Rust panic reaches Dart as a PanicException, not an FfiSmbError.
      throw BackendUnreachable(e.toString());
    }
  }

  static BackendFailure _mapError(native.FfiSmbError e) => switch (e.kind) {
        native.FfiSmbErrorKind.unauthorized => const BackendUnauthorized(),
        native.FfiSmbErrorKind.accessDenied => BackendPermissionLost(e.message),
        native.FfiSmbErrorKind.notFound => BackendNotFound(e.message),
        native.FfiSmbErrorKind.smb1Only =>
          const BackendUnreachable(kSmb1OnlyReason),
        native.FfiSmbErrorKind.unreachable ||
        native.FfiSmbErrorKind.unsupported ||
        native.FfiSmbErrorKind.other =>
          BackendUnreachable(e.message),
      };

  static native.FfiSmbTarget _target(SmbTarget t) =>
      native.FfiSmbTarget(host: t.host, port: t.port, share: t.share);

  static native.FfiSmbCredentials _creds(SmbCredentials c) =>
      native.FfiSmbCredentials(
        user: c.user,
        password: c.password,
        domain: c.domain,
      );

  static FileEntry _entry(native.FfiSmbEntry e) => FileEntry(
        path: e.path,
        name: e.name,
        isDir: e.isDir,
        size: e.size.toInt(),
        modified: DateTime.fromMillisecondsSinceEpoch(
          e.modifiedMs.toInt(),
          isUtc: true,
        ),
        unreadable: e.unreadable,
      );

  @override
  Future<List<FileEntry>> list(SmbTarget t, SmbCredentials c, String dir) =>
      _run(() async {
        final entries = await native.smbList(
            target: _target(t), creds: _creds(c), dir: dir);
        return [for (final e in entries) _entry(e)];
      });

  @override
  Future<FileEntry?> stat(SmbTarget t, SmbCredentials c, String path) =>
      _run(() async {
        final e = await native.smbStat(
            target: _target(t), creds: _creds(c), path: path);
        return e == null ? null : _entry(e);
      });

  @override
  Future<void> probe(SmbTarget t, SmbCredentials c, String root) => _run(
        () => native.smbProbe(target: _target(t), creds: _creds(c), root: root),
      );

  @override
  Future<List<String>> listShares(String host, int port, SmbCredentials c) =>
      _run(
          () => native.smbListShares(host: host, port: port, creds: _creds(c)));

  @override
  Future<String> open(
    String accountId,
    SmbTarget t,
    SmbCredentials c,
    String path,
  ) =>
      _run(
        () => native.smbOpen(
          accountId: accountId,
          target: _target(t),
          creds: _creds(c),
          path: path,
        ),
      );

  @override
  Future<void> closeAccount(String accountId) =>
      _run(() => native.smbCloseAccount(accountId: accountId));

  @override
  Future<ProxyHeal> healListener() async {
    final heal = await _run<native.FfiHeal>(() => native.smbHealListener());
    final result = switch (heal) {
      native.FfiHeal.healthy => ProxyHeal.healthy,
      native.FfiHeal.reboundSamePort => ProxyHeal.reboundSamePort,
      native.FfiHeal.reboundNewPort => ProxyHeal.reboundNewPort,
    };
    if (result != ProxyHeal.healthy) _heals.add(result);
    return result;
  }

  @override
  Stream<ProxyHeal> get heals => _heals.stream;
}

final smbNativeProvider = Provider<SmbNative>((_) => FfiSmbNative());
