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
import 'backend/webdav_backend.dart';
import 'files_account.dart';
import 'files_media_source.dart';
import 'files_providers.dart';
import 'files_scan_controller.dart';
import 'index/file_library_index.dart';
import 'media_names.dart';

/// `r` + the first 12 hex characters of SHA-256 over [path].
String filesRootId(String path) =>
    'r${sha256.convert(utf8.encode(path)).toString().substring(0, 12)}';

/// [path] without trailing separators, except a bare `/`.
String trimRootPath(String path) {
  var p = path;
  while (p.length > 1 && (p.endsWith('/') || p.endsWith(r'\'))) {
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
  Future<SourceId> _save(SourceAccountRecord record) async {
    await _ref.read(sourceRecordsProvider.notifier).putAccount(record);
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
    await _addRoot(sourceId, kFilesLocalAccountId, path: path, kind: kind);
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
