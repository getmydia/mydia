/// Where third-party accounts and servers live between launches. Tokens are
/// not here; see `SourceSecrets`.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive_ce/hive.dart';

import '../../storage/app_hive.dart';
import '../source.dart';
import 'source_records.dart';

abstract interface class SourceStore {
  Future<SourceSnapshot> load();
  Future<void> putAccount(SourceAccountRecord record);
  Future<void> removeAccount(String accountId);
  Future<void> setActive(SourceId? id);
}

class InMemorySourceStore implements SourceStore {
  final _accounts = <String, SourceAccountRecord>{};
  SourceId? _active;

  @override
  Future<SourceSnapshot> load() async => SourceSnapshot(
        accounts: _sorted(_accounts.values),
        activeId: _active,
      );

  @override
  Future<void> putAccount(SourceAccountRecord record) async =>
      _accounts[record.account.id] = record;

  @override
  Future<void> removeAccount(String accountId) async =>
      _accounts.remove(accountId);

  @override
  Future<void> setActive(SourceId? id) async => _active = id;
}

class HiveSourceStore implements SourceStore {
  HiveSourceStore(this._box);

  static const boxName = 'source_accounts';
  static const _activeKey = 'active';
  static const _accountPrefix = 'account:';

  static Future<HiveSourceStore> open() async {
    await initAppHive();
    return HiveSourceStore(await Hive.openBox<String>(boxName));
  }

  final Box<String> _box;

  @override
  Future<SourceSnapshot> load() async {
    final accounts = <SourceAccountRecord>[];
    for (final key in _box.keys.whereType<String>()) {
      if (!key.startsWith(_accountPrefix)) continue;
      try {
        final json = jsonDecode(_box.get(key)!) as Map<String, dynamic>;
        accounts.add(SourceAccountRecord.fromJson(json));
      } catch (e) {
        // One bad record must not hide every other server.
        debugPrint('[Sources] Skipping unreadable record $key: $e');
      }
    }
    final active = _box.get(_activeKey);
    return SourceSnapshot(
      accounts: _sorted(accounts),
      activeId: active == null ? null : SourceId(active),
    );
  }

  @override
  Future<void> putAccount(SourceAccountRecord record) => _box.put(
      '$_accountPrefix${record.account.id}', jsonEncode(record.toJson()));

  @override
  Future<void> removeAccount(String accountId) =>
      _box.delete('$_accountPrefix$accountId');

  @override
  Future<void> setActive(SourceId? id) =>
      id == null ? _box.delete(_activeKey) : _box.put(_activeKey, id.value);
}

List<SourceAccountRecord> _sorted(Iterable<SourceAccountRecord> records) =>
    records.toList()..sort((a, b) => a.addedAtMs.compareTo(b.addedAtMs));
