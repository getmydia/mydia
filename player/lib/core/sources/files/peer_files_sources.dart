/// The files libraries paired players lend this one, as sources.
///
/// Each account a member lends is a [Source] of kind files, derived from
/// [PeerFilesClient.accounts] and never stored: it cannot be renamed,
/// rescanned or removed here, and it goes when its host stops lending it.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../p2p/media_proxy_factory.dart' show mediaProxyProvider;
import '../../p2p/p2p_service.dart' show p2pServiceProvider;
import '../../p2p/peer_files_backend.dart';
import '../../p2p/peer_files_client.dart';
import '../../p2p/peer_files_store.dart';
import '../source.dart';
import '../sources_providers.dart' show isWebProvider;
import 'index/file_library_index.dart';

/// `p` + 12 hex characters + `_`, the prefix [peerFilesAccountId] gives.
final _peerAccountId = RegExp(r'^p[0-9a-f]{12}_');
const _peerPrefixLength = 14;

/// Whether [accountId] is a library lent by a paired player.
bool isPeerFilesAccountId(String accountId) =>
    _peerAccountId.hasMatch(accountId);

/// Whether [source] is a library lent by a paired player. Every place that
/// edits a files source, or writes into its index, checks this: the index
/// is the host's, and the next copy fetched replaces whatever was written.
bool isPeerFilesSource(Source source) =>
    isPeerFilesAccountId(source.account.id);

/// The host's own id for the account behind the peer account
/// [localAccountId]: what reads name and sync keys carry.
String peerFilesHostAccountId(String localAccountId) =>
    localAccountId.substring(_peerPrefixLength);

/// What the client lends this device right now. Empty on web, which
/// neither lends nor borrows, and when the copies' box failed to open.
final peerFilesAccountsProvider =
    NotifierProvider<_PeerFilesAccounts, List<PeerSharedAccount>>(
        _PeerFilesAccounts.new);

class _PeerFilesAccounts extends Notifier<List<PeerSharedAccount>> {
  @override
  List<PeerSharedAccount> build() {
    if (ref.watch(isWebProvider)) return const [];
    try {
      ref.watch(peerFilesStoreProvider);
    } catch (e) {
      debugPrint('[PeerFiles] No copies of lent libraries: $e');
      return const [];
    }
    final accounts = ref.watch(peerFilesClientProvider).accounts;
    void changed() {
      final next = accounts.value;
      final gone = {for (final a in state) a.nodeId}
          .difference({for (final a in next) a.nodeId});
      state = next;
      // A host that lends nothing any more needs no proxy target. One still
      // lending keeps its target, and with it any playback in progress.
      for (final nodeId in gone) {
        unawaited(PeerFilesBackend.releaseHost(
            nodeId, () => ref.read(mediaProxyProvider)));
      }
    }

    accounts.addListener(changed);
    ref.onDispose(() {
      // The client may already have disposed its notifier.
      try {
        accounts.removeListener(changed);
      } catch (_) {}
    });
    return accounts.value;
  }
}

/// The node id of each paired player as it connects. A seam so tests can
/// connect a host.
final peerConnectedProvider = Provider<Stream<String>>(
    (ref) => ref.watch(p2pServiceProvider).onPeerConnected);

/// One source per lent account, labelled with the lending device's name
/// and the account's, as "Living Room TV · Movies".
final peerFilesSourcesProvider = Provider<List<Source>>((ref) => [
      for (final a in ref.watch(peerFilesAccountsProvider)) peerFilesSource(a),
    ]);

Source peerFilesSource(PeerSharedAccount shared) {
  final id = shared.localAccountId;
  final name = '${shared.deviceName} · ${shared.wire.name}';
  return Source(
    account: ProviderAccount(
      id: id,
      kind: SourceKind.files,
      displayName: name,
      storageNamespace: 'source/$id',
      activeProfileId: kOwnerProfileId,
    ),
    profile: SourceProfile(
      id: kOwnerProfileId,
      accountId: id,
      name: 'Owner',
      isOwner: true,
    ),
    server: SourceServer(
      id: id,
      accountId: id,
      profileId: kOwnerProfileId,
      name: name,
      // The lending device, which every read is sent to.
      machineIdentifier: shared.nodeId,
      owned: false,
    ),
  );
}

/// The live copy of the lent account [localAccountId]'s index. Read again
/// on every change to the store, so a fetch that lands a new copy rebuilds
/// whatever reads this on it; an unchanged copy is the same instance and
/// rebuilds nothing.
final peerFilesIndexProvider =
    Provider.family<FileLibraryIndex, String>((ref, localAccountId) {
  final store = ref.watch(peerFilesStoreProvider);
  void changed() => ref.invalidateSelf();
  store.changes.addListener(changed);
  ref.onDispose(() => store.changes.removeListener(changed));
  return store.index(localAccountId);
});
