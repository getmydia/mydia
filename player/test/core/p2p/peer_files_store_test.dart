import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:player/core/p2p/peer_files_store.dart';
import 'package:player/core/p2p/peer_files_wire.dart';
import 'package:player/core/sources/files/index/file_library_index.dart';
import 'package:player/core/sources/files/media_names.dart';
import 'package:player/native/lib.dart';

const _id = 'p0123456789ab_flocal';

/// A box that fails the [failAt]th write touching a key that starts with
/// [failPrefix], as a full disk or a crash would part way through a fetch.
class _FlakyBox implements Box<Map<dynamic, dynamic>> {
  _FlakyBox(this._inner);

  final Box<Map<dynamic, dynamic>> _inner;
  String? failPrefix;
  int failAt = 0;
  var _writes = 0;

  /// Every key `put` was called with, failing or not.
  final putKeys = <dynamic>[];

  void _count(Iterable<dynamic> keys) {
    final prefix = failPrefix;
    if (prefix == null) return;
    if (!keys.any((k) => k is String && k.startsWith(prefix))) return;
    if (++_writes == failAt) throw HiveError('disk full');
  }

  @override
  Iterable<dynamic> get keys => _inner.keys;
  @override
  Map<dynamic, dynamic>? get(dynamic key,
          {Map<dynamic, dynamic>? defaultValue}) =>
      _inner.get(key, defaultValue: defaultValue);
  @override
  Future<void> put(dynamic key, Map<dynamic, dynamic> value) async {
    putKeys.add(key);
    _count([key]);
    await _inner.put(key, value);
  }

  @override
  Future<void> putAll(Map<dynamic, Map<dynamic, dynamic>> entries) async {
    _count(entries.keys);
    await _inner.putAll(entries);
  }

  @override
  Future<void> delete(dynamic key) => _inner.delete(key);
  @override
  Future<void> deleteAll(Iterable<dynamic> keys) => _inner.deleteAll(keys);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

final _t = DateTime.fromMillisecondsSinceEpoch(1700000000000);

LibraryRoot _root(String id) => LibraryRoot(
      id: id,
      path: '/media/$id',
      kind: FilesLibraryKind.movies,
      title: id,
    );

IndexedFile _file(String root, String name) => IndexedFile(
      key: fileKeyFor(root, name),
      rootId: root,
      path: name,
      size: 1,
      modified: _t,
      firstSeen: _t,
    );

FlutterWireIndexPage _page({
  List<LibraryRoot> roots = const [],
  List<IndexedFile> files = const [],
  List<MatchedMovie> movies = const [],
}) =>
    FlutterWireIndexPage(
      roots: encodeJsonRecords(roots, (r) => r.toMap()),
      files: encodeJsonRecords(files, (f) => f.toMap()),
      groups: const [],
      movies: encodeJsonRecords(movies, (m) => m.toMap()),
      shows: const [],
    );

void main() {
  late Directory dir;
  late Box<Map<dynamic, dynamic>> raw;
  late _FlakyBox box;
  late PeerFilesStore store;
  var n = 0;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('peer_files_store_test');
    Hive.init(dir.path);
    raw = await Hive.openBox<Map<dynamic, dynamic>>('pfi_${n++}');
    box = _FlakyBox(raw);
    store = PeerFilesStore(box);
  });

  tearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  Iterable<String> keysOf(String prefix) =>
      raw.keys.whereType<String>().where((k) => k.startsWith(prefix));

  test('an account never fetched reads as empty with no revision', () {
    expect(store.revision(_id), isNull);
    expect(store.index(_id).files(), isEmpty);
    expect(store.index(_id).accountId, startsWith('$_id@'));
  });

  test('replace_drops_old_generation', () async {
    await store.replace(_id, 1, [
      _page(roots: [_root('ra')], files: [_file('ra', 'Old Lamp.mkv')]),
    ]);
    final first = store.index(_id);
    expect(first.accountId, '$_id@1');
    expect(first.files().values.map((f) => f.path), ['Old Lamp.mkv']);
    // Cheap to ask for again: the same instance until the next flip.
    expect(identical(store.index(_id), first), isTrue);

    await store.replace(_id, 4, [
      _page(roots: [_root('rb')]),
      _page(
        files: [_file('rb', 'New Kite.mkv')],
        movies: [const MatchedMovie(tmdbId: 7, title: 'New Kite')],
      ),
    ]);
    final second = store.index(_id);
    expect(second.accountId, '$_id@2');
    expect(second.roots().map((r) => r.id), ['rb']);
    expect(second.files().values.map((f) => f.path), ['New Kite.mkv']);
    expect(second.movie(7)?.title, 'New Kite');
    expect(store.revision(_id), 4);
    expect(keysOf('$_id@1/'), isEmpty);

    // The flip is on disk: a fresh store over the same box agrees.
    final reopened = PeerFilesStore(box);
    expect(reopened.revision(_id), 4);
    expect(reopened.index(_id).files().values.map((f) => f.path),
        ['New Kite.mkv']);
  });

  test('replace_is_atomic', () async {
    await store.replace(_id, 1, [
      _page(roots: [_root('ra')], files: [_file('ra', 'Old Lamp.mkv')]),
    ]);

    box
      ..failPrefix = '$_id@2/'
      ..failAt = 3;
    await expectLater(
      store.replace(_id, 2, [
        for (var i = 0; i < 5; i++) _page(files: [_file('ra', 'Part $i.mkv')]),
      ]),
      throwsA(isA<HiveError>()),
    );

    expect(store.revision(_id), 1);
    expect(
        store.index(_id).files().values.map((f) => f.path), ['Old Lamp.mkv']);
    expect(PeerFilesStore(box).index(_id).files().values.map((f) => f.path),
        ['Old Lamp.mkv']);

    // The next fetch starts clean: nothing of the broken one survives.
    box.failPrefix = null;
    await store.replace(_id, 3, [
      _page(files: [_file('ra', 'Whole.mkv')]),
    ]);
    expect(store.revision(_id), 3);
    expect(store.index(_id).files().values.map((f) => f.path), ['Whole.mkv']);
    final live = store.index(_id).accountId;
    expect(
      raw.keys
          .whereType<String>()
          .where((k) => k.startsWith('$_id@') && !k.startsWith('$live/')),
      isEmpty,
    );
  });

  test('remove_deletes_everything', () async {
    const other = '${_id}2';
    await store.replace(_id, 1, [
      _page(roots: [_root('ra')], files: [_file('ra', 'Old Lamp.mkv')]),
    ]);
    await store.saveAccount(
      _id,
      nodeId: 'node-tv',
      wire: FlutterWireSharedAccount(
        accountId: 'flocal',
        kind: 'local',
        name: 'Films',
        revision: BigInt.one,
      ),
    );
    await store.replace(other, 1, [
      _page(files: [_file('ra', 'Neighbour.mkv')]),
    ]);

    await store.remove(_id);

    expect(store.revision(_id), isNull);
    expect(store.index(_id).files(), isEmpty);
    expect(store.storedAccounts(), isEmpty);
    expect(keysOf(_id).where((k) => !k.startsWith(other)), isEmpty);
    expect(raw.keys.whereType<String>().where((k) => k.endsWith('/$_id')),
        isEmpty);
    // A neighbouring id sharing the prefix is untouched.
    expect(store.index(other).files().values.map((f) => f.path),
        ['Neighbour.mkv']);
  });

  test('saved accounts read back with their host and manifest entry', () async {
    await store.saveAccount(
      _id,
      nodeId: 'node-tv',
      wire: FlutterWireSharedAccount(
        accountId: 'flocal',
        kind: 'local',
        name: 'Films',
        revision: BigInt.from(9),
      ),
    );
    final stored = PeerFilesStore(box).storedAccounts();
    expect(stored, hasLength(1));
    expect(stored.single.localAccountId, _id);
    expect(stored.single.nodeId, 'node-tv');
    expect(stored.single.wire.name, 'Films');
    expect(stored.single.wire.kind, 'local');
    expect(stored.single.wire.dedupeKey, isNull);
    expect(stored.single.wire.revision, BigInt.from(9));
  });

  test('saving_an_unchanged_account_writes_nothing', () async {
    final wire = FlutterWireSharedAccount(
      accountId: 'flocal',
      kind: 'local',
      name: 'Films',
      revision: BigInt.two,
    );
    await store.saveAccount(_id, nodeId: 'node-tv', wire: wire);
    expect(box.putKeys, ['account/$_id']);

    await store.saveAccount(_id, nodeId: 'node-tv', wire: wire);
    expect(box.putKeys, hasLength(1));

    await store.saveAccount(_id,
        nodeId: 'node-tv',
        wire: FlutterWireSharedAccount(
          accountId: 'flocal',
          kind: 'local',
          name: 'Films',
          revision: BigInt.from(3),
        ));
    expect(box.putKeys, hasLength(2));
  });

  test('sweep_deletes_records_no_pointer_reaches', () async {
    const other = 'p0000000000ff_s1';
    await store.replace(_id, 1, [
      _page(files: [_file('ra', 'Old Lamp.mkv')]),
    ]);
    await store.replace(_id, 2, [
      _page(files: [_file('ra', 'New Kite.mkv')]),
    ]);
    // A crash between a flip and its cleanup, one part way through the next
    // fetch, and an account whose pointer never landed.
    await raw.putAll({
      '$_id@1/file/a': _file('ra', 'Stale A.mkv').toMap(),
      '$_id@3/file/b': _file('ra', 'Half B.mkv').toMap(),
      '$other@1/file/c': _file('ra', 'Lost C.mkv').toMap(),
    });

    final reopened = PeerFilesStore(box);
    await reopened.sweep();

    expect(raw.keys.whereType<String>().where((k) => k.contains('@')),
        everyElement(startsWith('$_id@2/')));
    expect(reopened.index(_id).files().values.map((f) => f.path),
        ['New Kite.mkv']);
    expect(reopened.revision(_id), 2);
  });
}
