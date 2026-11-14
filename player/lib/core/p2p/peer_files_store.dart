/// The copies of paired players' files indexes this device browses, kept in
/// the `peer_files_index` box.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce/hive.dart';

import '../../native/lib.dart';
import '../sources/files/index/file_library_index.dart';
import 'peer_files_wire.dart';

/// One lent account as this device last stored it.
typedef StoredPeerAccount = ({
  String localAccountId,
  String nodeId,
  FlutterWireSharedAccount wire,
});

/// Each peer account's records live under a generation,
/// `<localAccountId>@<gen>/<type>/<id>`, read through an ordinary
/// [FileLibraryIndex] whose account id is `<localAccountId>@<gen>`.
///
/// `meta/<localAccountId>` holds `{gen, revision}` and is the only thing that
/// says which generation is live. A fetch writes the next generation beside
/// the live one and flips the pointer once every page is stored, so a fetch
/// that fails or is cut short by a crash leaves the live copy as it was.
/// `account/<localAccountId>` remembers who lent the account and its last
/// manifest entry, so the library browses before any host answers.
class PeerFilesStore {
  PeerFilesStore(this._box);

  static const boxName = 'peer_files_index';

  final Box<Map<dynamic, dynamic>> _box;

  /// Built once per generation: an index reads every key of the box when
  /// it is constructed, and sources ask for it often.
  final _indexes = <String, FileLibraryIndex>{};

  static String _metaKey(String id) => 'meta/$id';
  static String _accountKey(String id) => 'account/$id';
  static String _generation(String id, int gen) => '$id@$gen';

  int _gen(String id) => (_box.get(_metaKey(id))?['gen'] as int?) ?? 0;

  /// The live copy of [localAccountId]'s index, empty before its first
  /// fetch lands.
  FileLibraryIndex index(String localAccountId) {
    final generation = _generation(localAccountId, _gen(localAccountId));
    return _indexes[generation] ??=
        FileLibraryIndex(_box, accountId: generation);
  }

  /// The host revision the live copy was fetched at, null before the first.
  int? revision(String localAccountId) =>
      _box.get(_metaKey(localAccountId))?['revision'] as int?;

  /// Keys of [id]'s index records, of every generation but [keep].
  List<String> _recordKeys(String id, {int? keep}) {
    final all = '$id@';
    final kept = keep == null ? null : '${_generation(id, keep)}/';
    return [
      for (final k in _box.keys)
        if (k is String &&
            k.startsWith(all) &&
            (kept == null || !k.startsWith(kept)))
          k,
    ];
  }

  /// Stores [pages] as [localAccountId]'s index at [revision].
  ///
  /// Writes the next generation, flips the pointer to it, then deletes the
  /// old one. Throws if a page cannot be decoded or stored, leaving the live
  /// copy untouched.
  Future<void> replace(
    String localAccountId,
    int revision,
    List<FlutterWireIndexPage> pages,
  ) async {
    final live = _gen(localAccountId);
    final next = live + 1;
    // Whatever a cut-short fetch or cleanup left behind, so the new
    // generation starts empty and nothing stale is read into it.
    await _box.deleteAll(_recordKeys(localAccountId, keep: live));
    _indexes.remove(_generation(localAccountId, next));
    final staging =
        FileLibraryIndex(_box, accountId: _generation(localAccountId, next));
    for (final page in pages) {
      await staging.putRecords(
        roots: decodeJsonRecords(page.roots, LibraryRoot.fromMap),
        files: decodeJsonRecords(page.files, IndexedFile.fromMap),
        groups: decodeJsonRecords(page.groups, GroupMatch.fromMap),
        movies: decodeJsonRecords(page.movies, MatchedMovie.fromMap),
        shows: decodeJsonRecords(page.shows, MatchedShow.fromMap),
      );
    }
    await _box.put(_metaKey(localAccountId), {
      'gen': next,
      'revision': revision,
    });
    _indexes[_generation(localAccountId, next)] = staging;
    _indexes.remove(_generation(localAccountId, live));
    await _box.deleteAll(_recordKeys(localAccountId, keep: next));
  }

  /// Remembers that [nodeId] lends [wire] as [localAccountId].
  Future<void> saveAccount(
    String localAccountId, {
    required String nodeId,
    required FlutterWireSharedAccount wire,
  }) =>
      _box.put(_accountKey(localAccountId), {
        'nodeId': nodeId,
        'accountId': wire.accountId,
        'kind': wire.kind,
        'name': wire.name,
        'dedupeKey': wire.dedupeKey,
        'revision': wire.revision.toString(),
      });

  /// Every account [saveAccount] stored and [remove] has not removed.
  List<StoredPeerAccount> storedAccounts() {
    const prefix = 'account/';
    final out = <StoredPeerAccount>[];
    for (final k in _box.keys) {
      if (k is! String || !k.startsWith(prefix)) continue;
      final m = _box.get(k);
      if (m == null) continue;
      try {
        out.add((
          localAccountId: k.substring(prefix.length),
          nodeId: m['nodeId'] as String,
          wire: FlutterWireSharedAccount(
            accountId: m['accountId'] as String,
            kind: m['kind'] as String,
            name: m['name'] as String,
            dedupeKey: m['dedupeKey'] as String?,
            revision: BigInt.parse(m['revision'] as String),
          ),
        ));
      } catch (_) {
        // An unreadable entry is refetched from its host's manifest.
        continue;
      }
    }
    return out;
  }

  /// Deletes [localAccountId]'s index, pointer and account entry.
  Future<void> remove(String localAccountId) async {
    await _box.deleteAll([
      ..._recordKeys(localAccountId),
      _metaKey(localAccountId),
      _accountKey(localAccountId),
    ]);
    _indexes.removeWhere((k, _) => k.startsWith('$localAccountId@'));
  }
}

/// The store over its box, opened with the files library boxes at startup.
final peerFilesStoreProvider = Provider<PeerFilesStore>((ref) =>
    PeerFilesStore(Hive.box<Map<dynamic, dynamic>>(PeerFilesStore.boxName)));
