/// Adding and removing files libraries: the account record, its credentials
/// and its roots.
library;

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../cache/watcher_registry.dart' show invalidatorProvider;
import '../connection/source_connection.dart' show isPrivateHost;
import '../source.dart';
import '../sources_providers.dart';
import '../store/source_records.dart';
import '../store/source_secrets.dart';
import 'backend/file_system_backend.dart';
import 'backend/local_path_backend.dart';
import 'backend/webdav_backend.dart';
import 'files_account.dart';
import 'files_media_source.dart';
import 'files_providers.dart';
import 'files_scan_controller.dart';
import 'index/file_library_index.dart';
import 'media_names.dart';
import 'smb_addresses.dart';
import 'smb_native.dart' show SmbTarget, smbNativeProvider;

/// `r` + the first 12 hex characters of SHA-256 over [path].
String filesRootId(String path) =>
    'r${sha256.convert(utf8.encode(path)).toString().substring(0, 12)}';

/// [path] without trailing separators, except a bare `/` or a drive root
/// (`C:/`, since `C:` alone means the drive's current directory).
String trimRootPath(String path) {
  var p = path;
  while (p.length > 1 &&
      (p.endsWith('/') || p.endsWith(r'\')) &&
      !RegExp(r'^[A-Za-z]:[/\\]$').hasMatch(p)) {
    p = p.substring(0, p.length - 1);
  }
  return p;
}

/// The last segment of [path], the name a root is shown under.
String filesRootTitle(String path) {
  final segments = trimRootPath(path)
      .split(RegExp(r'[/\\]'))
      .where((s) => s.isNotEmpty)
      .toList();
  return segments.isEmpty ? path : segments.last;
}

/// [url] as the base a WebDAV account stores and probes.
Uri webDavBase(Uri url) => Uri.parse(normalizeWebDavUrl(url));

/// Builds a WebDAV backend from what the viewer typed, before anything is
/// saved, over [client], which the caller owns and closes. Tests override it
/// with a fake.
typedef WebDavConnector = FileSystemBackend Function(
    Uri base, String user, String password, http.Client client);

final webDavConnectorProvider = Provider<WebDavConnector>(
  (_) => (base, user, password, client) =>
      WebDavBackend(base: base, user: user, password: password, client: client),
);

final filesAccountsProvider =
    Provider<FilesAccounts>((ref) => FilesAccounts(ref));

class FilesAccounts {
  FilesAccounts(this._ref);

  final Ref _ref;

  Future<SourceAccountRecord?> _stored(String accountId) async {
    final snapshot = await _ref.read(sourceRecordsProvider.future);
    return snapshot.accounts
        .where((a) => a.account.id == accountId)
        .firstOrNull;
  }

  SourceProfile _owner(String accountId) => SourceProfile(
        id: kOwnerProfileId,
        accountId: accountId,
        name: 'Owner',
        isOwner: true,
      );

  /// Writes [record] and rebuilds its sources, so a cleared `needsReauth`
  /// and new credentials are read.
  Future<SourceId> _save(SourceAccountRecord record,
      {bool replaceOnly = false}) async {
    await _ref
        .read(sourceRecordsProvider.notifier)
        .putAccount(record, replaceOnly: replaceOnly);
    for (final source in record.sources) {
      _ref.invalidate(mediaSourceProvider(source.id));
    }
    return record.sources.first.id;
  }

  Future<void> _addRoot(SourceId id, String accountId,
      {required String path, required FilesLibraryKind kind}) async {
    final p = trimRootPath(path);
    await _ref.read(filesIndexProvider(accountId)).putRoot(LibraryRoot(
          id: filesRootId(p),
          path: p,
          kind: kind,
          title: filesRootTitle(p),
        ));
    await _ref
        .read(invalidatorProvider)
        .invalidate(FilesMediaSource.groupLandedTargets(id));
    unawaited(_ref
        .read(filesScanProvider(id).notifier)
        .rescan()
        .catchError((Object e) {
      debugPrint('[FilesAccounts] Scan after adding a folder failed: $e');
    }));
  }

  /// Adds a folder on this device, creating the [kFilesLocalAccountId]
  /// account, named [accountName], on first use. Adding one clears a
  /// `needsReauth` left by a folder that could not be read.
  Future<SourceId> addLocalRoot({
    required String path,
    required FilesLibraryKind kind,
    required String accountName,
  }) async {
    final existing = await _stored(kFilesLocalAccountId);
    final SourceAccountRecord record;
    if (existing != null) {
      record = existing.copyWith(
          account: existing.account.copyWith(needsReauth: false));
    } else {
      const id = kFilesLocalAccountId;
      record = SourceAccountRecord(
        account: ProviderAccount(
          id: id,
          kind: SourceKind.files,
          displayName: accountName,
          storageNamespace: SourceSecrets.newStorageNamespace(id),
          activeProfileId: kOwnerProfileId,
        ),
        profiles: [_owner(id)],
        servers: [
          SourceServer(
            id: kFilesLocalServerId,
            accountId: id,
            profileId: kOwnerProfileId,
            name: accountName,
          ),
        ],
        addedAtMs: DateTime.now().millisecondsSinceEpoch,
      );
    }
    final sourceId = await _save(record);
    await _addRoot(sourceId, kFilesLocalAccountId,
        path: portableLocalPath(path), kind: kind);
    return sourceId;
  }

  /// Saves a WebDAV share. The credentials are written before the record.
  /// A URL already saved reuses its account: the credentials are replaced
  /// and `needsReauth` clears.
  Future<SourceId> addWebDavAccount({
    required Uri url,
    required String user,
    required String password,
  }) async {
    final id = webDavAccountId(url);
    final base = webDavBase(url);
    final existing = await _stored(id);
    final account = existing?.account.copyWith(needsReauth: false) ??
        ProviderAccount(
          id: id,
          kind: SourceKind.files,
          displayName: base.host,
          storageNamespace: SourceSecrets.newStorageNamespace(id),
          activeProfileId: kOwnerProfileId,
        );
    await _ref.read(sourceSecretsProvider).writeAccountToken(
        account, WebDavCredentials(user: user, password: password).toJson());
    final record = existing?.copyWith(account: account) ??
        SourceAccountRecord(
          account: account,
          profiles: [_owner(id)],
          servers: [
            SourceServer(
              id: id,
              accountId: id,
              profileId: kOwnerProfileId,
              name: base.host,
              connections: [
                ServerConnection(uri: base, local: isPrivateHost(base.host)),
              ],
            ),
          ],
          addedAtMs: DateTime.now().millisecondsSinceEpoch,
        );
    return _save(record);
  }

  /// Saves an SMB share. The credentials are written before the record. A
  /// URL already saved reuses its account: the credentials are replaced and
  /// `needsReauth` clears and the saved name is kept.
  ///
  /// A new account is named [displayName], or `<host>/<share>` with the share
  /// as typed, so two shares on one server are told apart.
  ///
  /// [url]'s host is the address that answered; [alternatives] are further
  /// hosts (the hostname, other addresses) in preference order. A share
  /// already saved under the same [serviceName], or at any of these hosts,
  /// is reused (see [findSmbAccount]) and its address list is updated.
  ///
  /// [signInAgain] only replaces the credentials of a stored account: one
  /// removed while the sign-in was in flight throws [StateError] and its
  /// credentials are not left behind, so a removal (or "Forgot PIN") sticks.
  Future<SourceId> addSmbAccount({
    required Uri url,
    required SmbCredentials credentials,
    String? displayName,
    bool signInAgain = false,
    List<String> alternatives = const [],
    String? serviceName,
  }) async {
    final base = Uri.parse(normalizeSmbUrl(url));
    final typedShare =
        url.pathSegments.where((s) => s.isNotEmpty).firstOrNull ?? '';
    final target = smbTargetOf(base);
    final connections = smbConnections(
      share: target.share,
      port: target.port,
      hosts: [target.host, ...alternatives],
    );
    final id = await findSmbAccount(
          share: target.share,
          hosts: [target.host, ...alternatives],
          serviceName: serviceName,
          port: target.port,
        ) ??
        smbAccountId(url);
    final name = displayName ?? '${base.host}/$typedShare';
    final existing = await _stored(id);
    if (signInAgain && existing == null) {
      throw StateError('SMB account $id was removed');
    }
    final account = existing?.account.copyWith(needsReauth: false) ??
        ProviderAccount(
          id: id,
          kind: SourceKind.files,
          displayName: name,
          storageNamespace: SourceSecrets.newStorageNamespace(id),
          activeProfileId: kOwnerProfileId,
        );
    await _ref
        .read(sourceSecretsProvider)
        .writeAccountToken(account, credentials.toJson());
    final record = existing == null
        ? SourceAccountRecord(
            account: account,
            profiles: [_owner(id)],
            servers: [
              SourceServer(
                id: id,
                accountId: id,
                profileId: kOwnerProfileId,
                name: name,
                connections: connections,
                serviceName: serviceName,
              ),
            ],
            addedAtMs: DateTime.now().millisecondsSinceEpoch,
          )
        : existing.copyWith(
            account: account,
            servers: [
              for (final server in existing.servers)
                server.copyWith(
                  connections: promoteSmbConnection(
                    server.connections,
                    connections.first,
                    discovered: connections.skip(1).toList(),
                  ),
                  serviceName: serviceName,
                ),
            ],
          );
    if (!signInAgain) return _save(record);
    try {
      return await _save(record, replaceOnly: true);
    } on StateError {
      // Removed after the check above: its credentials were deleted with it,
      // and the ones just written must go too.
      await _ref.read(sourceSecretsProvider).deleteAccountToken(account);
      rethrow;
    }
  }

  /// The id of a stored SMB account for [share] (case-insensitive) that has
  /// [serviceName] (non-null) or shares at least one of [hosts], on [port]
  /// (the port of its first connection).
  Future<String?> findSmbAccount({
    required String share,
    required List<String> hosts,
    String? serviceName,
    int port = kSmbDefaultPort,
  }) async {
    final wanted = {for (final h in hosts) normalizeSmbHost(h)};
    final snapshot = await _ref.read(sourceRecordsProvider.future);
    for (final record in snapshot.accounts) {
      if (!isSmbAccountId(record.account.id)) continue;
      for (final server in record.servers) {
        if (server.connections.isEmpty) continue;
        final stored = smbTargetsOf(server.connections);
        if (stored.first.share.toLowerCase() != share.toLowerCase()) continue;
        if (stored.first.port != port) continue;
        final sameService =
            serviceName != null && server.serviceName == serviceName;
        if (sameService ||
            stored.any((t) => wanted.contains(normalizeSmbHost(t.host)))) {
          return record.account.id;
        }
      }
    }
    return null;
  }

  /// Moves [reached] to the front of [accountId]'s addresses and adds the
  /// [discovered] ones. Does not rebuild the source: the backend that calls
  /// this is already connected. A no-op when the account is gone.
  Future<void> promoteSmbAddress(String accountId, SmbTarget reached,
      {List<SmbTarget> discovered = const []}) {
    // The read-modify-write runs inside the records queue, so a concurrent
    // `needsReauth` or lock change is never overwritten with stale data.
    return _ref.read(sourceRecordsProvider.notifier).updateServers(
          accountId,
          (servers) => [
            for (final server in servers)
              server.copyWith(
                connections: promoteSmbConnection(
                  server.connections,
                  smbConnectionOf(reached),
                  discovered: [for (final t in discovered) smbConnectionOf(t)],
                ),
              ),
          ],
        );
  }

  /// Replaces [accountId]'s addresses with [host], [port] and
  /// [alternatives], keeping the share, the id and the roots, and sets
  /// [serviceName] (cleared when null). Rebuilds the source and drops the
  /// native session. Throws [StateError] when the account is gone.
  Future<void> setSmbAddress(
    String accountId, {
    required String host,
    required int port,
    List<String> alternatives = const [],
    String? serviceName,
  }) async {
    final existing = await _stored(accountId);
    if (existing == null) {
      throw StateError('SMB account $accountId was removed');
    }
    final record = existing.copyWith(servers: [
      for (final server in existing.servers)
        server.copyWith(
          connections: smbConnections(
            share: smbTargetOf(server.connections.first.uri).share,
            port: port,
            hosts: [host, ...alternatives],
          ),
          serviceName: serviceName,
          clearServiceName: serviceName == null,
        ),
    ]);
    await _save(record, replaceOnly: true);
    await _ref.read(smbNativeProvider).closeAccount(accountId);
  }

  /// Adds [path], a path on the share, as a root of [id].
  Future<void> addSmbRoot(SourceId id,
          {required String path, required FilesLibraryKind kind}) =>
      addWebDavRoot(id, path: path, kind: kind);

  /// Adds [path], a server path on the share, as a root of [id].
  Future<void> addWebDavRoot(SourceId id,
      {required String path, required FilesLibraryKind kind}) async {
    final source =
        _ref.read(sourcesProvider).where((s) => s.id == id).firstOrNull;
    if (source == null) throw StateError('No files source $id');
    await _addRoot(id, source.account.id, path: path, kind: kind);
  }

  /// Drops [rootId] and its files from [id]'s index.
  Future<void> removeRoot(SourceId id, String rootId) async {
    final source =
        _ref.read(sourcesProvider).where((s) => s.id == id).firstOrNull;
    if (source == null) return;
    await _ref.read(filesIndexProvider(source.account.id)).removeRoot(rootId);
    await _ref
        .read(invalidatorProvider)
        .invalidate(FilesMediaSource.groupLandedTargets(id));
  }

  /// Removes the account: its credentials and record, then its index.
  Future<void> removeFilesAccount(String accountId) async {
    await _ref.read(sourceRecordsProvider.notifier).removeAccount(accountId);
    await _ref.read(filesIndexProvider(accountId)).clear();
  }
}
