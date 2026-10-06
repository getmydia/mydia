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

  /// Replaces every "Include in All servers" choice.
  Future<void> setAllServers(Map<SourceId, bool> choices);

  /// The account the previous single-server sign-in was migrated into. Set
  /// once, last, by the legacy migration; null on a fresh install.
  Future<String?> legacyInstanceId();
  Future<void> setLegacyInstanceId(String accountId);
}

class InMemorySourceStore implements SourceStore {
  final _accounts = <String, SourceAccountRecord>{};
  SourceId? _active;
  Map<SourceId, bool> _allServers = const {};
  String? _legacyInstanceId;

  @override
  Future<String?> legacyInstanceId() async => _legacyInstanceId;

  @override
  Future<void> setLegacyInstanceId(String accountId) async =>
      _legacyInstanceId = accountId;

  @override
  Future<SourceSnapshot> load() async => SourceSnapshot(
        accounts: _sorted(_accounts.values),
        activeId: _active,
        allServers: Map.unmodifiable(_allServers),
      );

  @override
  Future<void> setAllServers(Map<SourceId, bool> choices) async =>
      _allServers = Map.of(choices);

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
  static const _allServersKey = 'all_servers';
  static const _legacyInstanceIdKey = 'legacy_instance_id';
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
      allServers: _readAllServers(),
    );
  }

  Map<SourceId, bool> _readAllServers() {
    final raw = _box.get(_allServersKey);
    if (raw == null) return const {};
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return {
        for (final e in json.entries) SourceId(e.key): e.value as bool,
      };
    } catch (e) {
      // Like an unreadable account: the choices reset, nothing else fails.
      debugPrint('[Sources] Skipping unreadable All servers choices: $e');
      return const {};
    }
  }

  @override
  Future<void> setAllServers(Map<SourceId, bool> choices) => _box.put(
        _allServersKey,
        jsonEncode({for (final e in choices.entries) e.key.value: e.value}),
      );

  @override
  Future<void> putAccount(SourceAccountRecord record) => _box.put(
      '$_accountPrefix${record.account.id}', jsonEncode(record.toJson()));

  @override
  Future<void> removeAccount(String accountId) =>
      _box.delete('$_accountPrefix$accountId');

  @override
  Future<String?> legacyInstanceId() async => _box.get(_legacyInstanceIdKey);

  @override
  Future<void> setLegacyInstanceId(String accountId) =>
      _box.put(_legacyInstanceIdKey, accountId);

  @override
  Future<void> setActive(SourceId? id) =>
      id == null ? _box.delete(_activeKey) : _box.put(_activeKey, id.value);
}

List<SourceAccountRecord> _sorted(Iterable<SourceAccountRecord> records) =>
    records.toList()..sort((a, b) => a.addedAtMs.compareTo(b.addedAtMs));
