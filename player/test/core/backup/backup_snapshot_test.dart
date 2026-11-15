import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:player/core/backup/backup_meta_store.dart';
import 'package:player/core/backup/backup_records.dart';
import 'package:player/core/backup/backup_snapshot.dart';
import 'package:player/core/p2p/peer_group_secret.dart';
import 'package:player/core/p2p/peer_sync_records.dart';
import 'package:player/core/p2p/peer_sync_store.dart';
import 'package:player/core/player/subtitle_size.dart';
import 'package:player/core/settings/settings_service.dart';
import 'package:player/core/sources/files/files_account.dart';
import 'package:player/core/sources/files/index/index_records.dart';
import 'package:player/core/sources/files/media_names.dart';
import 'package:crypto/crypto.dart';
import 'package:player/core/sources/jellyfin/jellyfin_identity.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/store/source_records.dart';
import 'package:player/core/sources/store/source_store.dart';
import 'package:player/core/theme/glass_material.dart';
import 'package:player/core/theme/theme_preset.dart';

import '../../test_utils/mock_auth_storage.dart';

/// One install: every store the snapshot reads and writes, in memory.
class _Device {
  _Device() {
    snapshot = BackupSnapshot(
      peerSync: sync,
      authStorage: auth,
      meta: meta,
      loadSources: sources.load,
      putAccount: (r) async {
        putAccountCalls.add(r.account.id);
        // The sources layer writes tokens before the record: by the time
        // the record lands, its secrets must already be in storage.
        tokensAtPut[r.account.id] = {
          for (final k in auth.keys)
            if (k.startsWith('${r.account.storageNamespace}/')) k,
        };
        await sources.putAccount(r);
      },
      settings: settings,
      loadSubtitleLanguages: () async => subtitleLanguages,
      saveSubtitleLanguages: (l) async => subtitleLanguages = l,
      onRemoteFilesChanges: (w, p) async => remoteChanges.add((w, p)),
      rootsFor: (id) async => roots[id] ?? const [],
      putRoots: (id, r) async {
        // Roots land after the account record.
        expect(putAccountCalls, contains(id));
        if (failNextPutRoots) {
          failNextPutRoots = false;
          throw StateError('index locked');
        }
        roots[id] = [...?roots[id], ...r];
        putRootsCalls[id] = r;
      },
    );
  }

  final auth = MockAuthStorage();
  final sources = InMemorySourceStore();
  final sync = InMemoryPeerSyncStore();
  final metaStorage = InMemoryBackupMetaStorage();
  late final meta = BackupMetaStore(metaStorage);
  final roots = <String, List<LibraryRoot>>{};
  final putRootsCalls = <String, List<LibraryRoot>>{};
  bool failNextPutRoots = false;

  /// Storage keys other than the per-install fingerprint key.
  Iterable<String> get dataKeys =>
      auth.keys.where((k) => k != kBackupFingerprintKeyStorageKey);
  late final settings = SettingsService(storage: auth);
  List<String>? subtitleLanguages;
  final remoteChanges = <(Set<String>, Set<String>)>[];
  final putAccountCalls = <String>[];
  final tokensAtPut = <String, Set<String>>{};
  late final BackupSnapshot snapshot;
}

SourceAccountRecord _plex({Map<String, SourceLock> locks = const {}}) =>
    SourceAccountRecord(
      account: const ProviderAccount(
        id: 'p1',
        kind: SourceKind.plex,
        displayName: 'Night Harbor Plex',
        storageNamespace: 'source/p1',
        activeProfileId: kOwnerProfileId,
      ),
      profiles: const [
        SourceProfile(
            id: kOwnerProfileId, accountId: 'p1', name: 'Ana', isOwner: true),
      ],
      servers: const [
        SourceServer(
            id: 'srv1',
            accountId: 'p1',
            profileId: kOwnerProfileId,
            name: 'Night Harbor'),
      ],
      addedAtMs: 1000,
      serverLocks: locks,
    );

SourceAccountRecord _mydia() => SourceAccountRecord(
      account: const ProviderAccount(
        id: 'minst1',
        kind: SourceKind.mydia,
        displayName: 'Home server',
        storageNamespace: 'source/minst1',
        activeProfileId: kOwnerProfileId,
      ),
      profiles: const [
        SourceProfile(
            id: kOwnerProfileId,
            accountId: 'minst1',
            name: 'Owner',
            isOwner: true),
      ],
      servers: const [
        SourceServer(
            id: 'inst1',
            accountId: 'minst1',
            profileId: kOwnerProfileId,
            name: 'Home server'),
      ],
      addedAtMs: 2000,
    );

SourceAccountRecord _localFolders() => SourceAccountRecord(
      account: const ProviderAccount(
        id: kFilesLocalAccountId,
        kind: SourceKind.files,
        displayName: 'Folders',
        storageNamespace: 'source/$kFilesLocalAccountId',
        activeProfileId: kOwnerProfileId,
      ),
      profiles: const [
        SourceProfile(
            id: kOwnerProfileId,
            accountId: kFilesLocalAccountId,
            name: 'Owner',
            isOwner: true),
      ],
      servers: const [
        SourceServer(
            id: kFilesLocalServerId,
            accountId: kFilesLocalAccountId,
            profileId: kOwnerProfileId,
            name: 'Folders'),
      ],
      addedAtMs: 3000,
    );

Future<void> _addPlex(_Device d,
    {Map<String, SourceLock> locks = const {}}) async {
  await d.auth.write('source/p1/account_token', 'plex-admin-token');
  await d.auth.write('source/p1/owner/srv1/token', 'plex-server-token');
  await d.sources.putAccount(_plex(locks: locks));
}

Future<void> _addMydia(_Device d) async {
  await d.auth.write('source/minst1/account_token', '{"accessToken":"x"}');
  await d.sources.putAccount(_mydia());
}

AccountBackupRecord _account(List<BackupRecord> records, String id) =>
    records.whereType<AccountBackupRecord>().singleWhere(
          (r) => r.accountId == id,
        );

SettingBackupRecord? _setting(List<BackupRecord> records, String key) {
  for (final r in records.whereType<SettingBackupRecord>()) {
    if (r.settingKey == key) return r;
  }
  return null;
}

/// Wire round trip, so tests exercise what a real slot carries.
List<BackupRecord> _viaWire(List<BackupRecord> records) => [
      for (final r in records)
        BackupRecord.fromJson(
            jsonDecode(jsonEncode(r.toJson())) as Map<String, dynamic>)!,
    ];

const _now = 1700000000000;

void main() {
  group('collect then restore', () {
    test('reproduces the Plex account with its server token and the settings',
        () async {
      final a = _Device();
      await _addPlex(a);
      await a.settings.setDefaultQuality('1080p');
      await a.settings.setAutoSkipSegments(true);
      await a.settings.setSubtitleSize(SubtitleSize.large);
      await a.settings.setThemePreset(ThemePreset.values.last);
      await a.settings.setLocaleCode('pt-BR');
      await a.settings.setUpdateTrack('beta');
      await a.settings.setLibrarySort('p1:owner:srv1/lib1', 'title:asc');
      a.subtitleLanguages = ['pt', 'en'];

      final records = _viaWire(await a.snapshot.collect(nowMs: _now));

      final b = _Device();
      final result = await b.snapshot.apply(records,
          mode: BackupApplyMode.restore,
          fromDevice: 'Living Room TV',
          nowMs: _now + 1);

      expect(result.accountsAdded, 1);
      final restored = (await b.sources.load()).accounts.single;
      expect(restored.account.id, 'p1');
      expect(restored.account.needsReauth, isFalse);
      expect(restored.servers.single.id, 'srv1');
      expect(
          await b.auth.read('source/p1/owner/srv1/token'), 'plex-server-token');
      expect(await b.auth.read('source/p1/account_token'), 'plex-admin-token');
      expect(
          b.tokensAtPut['p1'],
          containsAll(
              ['source/p1/account_token', 'source/p1/owner/srv1/token']),
          reason: 'secrets are written before the record');

      expect(await b.settings.getDefaultQuality(), '1080p');
      expect(await b.settings.getAutoSkipSegments(), isTrue);
      expect(await b.settings.getSubtitleSize(), SubtitleSize.large);
      expect(await b.settings.getThemePreset(), ThemePreset.values.last.name);
      expect(await b.settings.getLocaleCode(), 'pt-BR');
      expect(await b.settings.getUpdateTrack(), 'beta');
      expect(
          await b.settings.getLibrarySort('p1:owner:srv1/lib1'), 'title:asc');
      expect(b.subtitleLanguages, ['pt', 'en']);
      expect(result.settingsApplied, greaterThanOrEqualTo(8));
    });

    test('a restored device collects the same updatedAt it restored', () async {
      final a = _Device();
      await _addPlex(a);
      await a.settings.setDefaultQuality('720p');
      final records = await a.snapshot.collect(nowMs: _now);

      final b = _Device();
      await b.snapshot.apply(_viaWire(records),
          mode: BackupApplyMode.restore, fromDevice: 'A', nowMs: _now + 5);
      final again = await b.snapshot.collect(nowMs: _now + 10);

      expect(
          _account(again, 'p1').updatedAt, _account(records, 'p1').updatedAt);
      expect(_setting(again, 'default_quality')!.updatedAt, _now);
    });

    test('watch and pin records merge and reach the files callback', () async {
      final a = _Device();
      await a.sync.setWatched('tmdb:movie:42', true, nowMs: _now - 10);
      await a.sync.setPin(
          groupKey: 'g1',
          isShow: true,
          tmdbId: 7,
          pinned: true,
          nowMs: _now - 5);
      final records = _viaWire(await a.snapshot.collect(nowMs: _now));

      for (final mode in BackupApplyMode.values) {
        final b = _Device();
        final result = await b.snapshot
            .apply(records, mode: mode, fromDevice: 'A', nowMs: _now + 1);
        expect(result.watchChanged, 1);
        expect(result.pinsChanged, 1);
        expect(b.sync.watchRecord('tmdb:movie:42')!.watched, isTrue);
        expect(b.sync.watchRecord('tmdb:movie:42')!.updatedAt, _now - 10);
        final pin = b.sync.pinRecord(isShow: true, groupKey: 'g1')!;
        expect(pin.pinned, isTrue);
        expect(pin.tmdbId, 7);
        expect(b.remoteChanges.single.$1, {'tmdb:movie:42'});
        expect(b.remoteChanges.single.$2,
            {pinSyncKey(isShow: true, groupKey: 'g1')});
      }
    });

    test('no watch or pin change does not call the files callback', () async {
      final b = _Device();
      await b.snapshot.apply(const [],
          mode: BackupApplyMode.live, fromDevice: 'A', nowMs: _now);
      expect(b.remoteChanges, isEmpty);
    });
  });

  group('collect', () {
    test('locks never appear in collected JSON', () async {
      final a = _Device();
      await _addPlex(a, locks: {'srv1': SourceLock.hidden});
      final records = await a.snapshot.collect(nowMs: _now);
      final json = jsonEncode([for (final r in records) r.toJson()]);
      expect(json, isNot(contains('serverLocks')));
      expect(json, isNot(contains('hidden')));
    });

    test('a restore writes the account with no locks', () async {
      final a = _Device();
      await _addPlex(a, locks: {'srv1': SourceLock.locked});
      final records = await a.snapshot.collect(nowMs: _now);
      // Even a record that somehow carries locks is restored unlocked.
      final tampered = [
        for (final r in records)
          if (r is AccountBackupRecord)
            AccountBackupRecord(
              key: r.key,
              recordJson: {
                ...r.recordJson,
                'serverLocks': {'srv1': 'locked'},
              },
              secrets: r.secrets,
              updatedAt: r.updatedAt,
            )
          else
            r,
      ];
      final b = _Device();
      await b.snapshot.apply(tampered,
          mode: BackupApplyMode.restore, fromDevice: 'A', nowMs: _now);
      expect((await b.sources.load()).accounts.single.serverLocks, isEmpty);
    });

    test('a Mydia account is collected without secrets, restored needsReauth',
        () async {
      final a = _Device();
      await _addMydia(a);
      final records = await a.snapshot.collect(nowMs: _now);
      final rec = _account(records, 'minst1');
      expect(rec.secrets, isEmpty);
      expect((rec.recordJson['account'] as Map)['needsReauth'], isTrue);
      expect(jsonEncode([for (final r in records) r.toJson()]),
          isNot(contains('accessToken')));

      final b = _Device();
      final result = await b.snapshot.apply(_viaWire(records),
          mode: BackupApplyMode.restore, fromDevice: 'A', nowMs: _now);
      expect(result.accountsAdded, 1);
      final restored = (await b.sources.load()).accounts.single;
      expect(restored.account.kind, SourceKind.mydia);
      expect(restored.account.needsReauth, isTrue);
      expect(await b.auth.read('source/minst1/account_token'), isNull);
    });

    test('a Mydia record carrying secrets still restores none', () async {
      final b = _Device();
      final rec = AccountBackupRecord(
        key: 'account:minst1',
        recordJson: _mydia().toJson(),
        secrets: const {'account_token': '{"accessToken":"x"}'},
        updatedAt: _now,
      );
      await b.snapshot.apply([rec],
          mode: BackupApplyMode.restore, fromDevice: 'A', nowMs: _now);
      expect(b.dataKeys, isEmpty);
      expect(
          (await b.sources.load()).accounts.single.account.needsReauth, isTrue);
    });

    test('the Jellyfin device id is never collected', () async {
      final a = _Device();
      await a.auth.write(JellyfinIdentity.deviceIdKey, 'device-abc');
      await a.auth.write('source/j1/account_token', 'jf-token');
      await a.sources.putAccount(SourceAccountRecord(
        account: const ProviderAccount(
          id: 'j1',
          kind: SourceKind.jellyfin,
          displayName: 'Jellyfin',
          storageNamespace: 'source/j1',
          activeProfileId: 'u1',
        ),
        profiles: const [
          SourceProfile(id: 'u1', accountId: 'j1', name: 'Ana', isOwner: true),
        ],
        servers: const [
          SourceServer(id: 's1', accountId: 'j1', profileId: 'u1', name: 'J'),
        ],
        addedAtMs: 1,
      ));
      final records = await a.snapshot.collect(nowMs: _now);
      expect(_account(records, 'j1').secrets, {'account_token': 'jf-token'});
      expect(jsonEncode([for (final r in records) r.toJson()]),
          isNot(contains('device-abc')));
    });

    test('Plex Home user tokens are collected per profile', () async {
      final a = _Device();
      await a.auth.write('source/p2/account_token', 'admin');
      await a.auth.write('source/p2/kid/user_token', 'kid-user');
      await a.auth.write('source/p2/kid/srvA/token', 'kid-server');
      await a.sources.putAccount(SourceAccountRecord(
        account: const ProviderAccount(
          id: 'p2',
          kind: SourceKind.plex,
          displayName: 'Plex',
          storageNamespace: 'source/p2',
          activeProfileId: 'kid',
        ),
        profiles: const [
          SourceProfile(id: 'owner', accountId: 'p2', name: 'A', isOwner: true),
          SourceProfile(id: 'kid', accountId: 'p2', name: 'K', isOwner: false),
        ],
        servers: const [
          SourceServer(
              id: 'srvA', accountId: 'p2', profileId: 'kid', name: 'S'),
        ],
        addedAtMs: 1,
      ));
      final records = await a.snapshot.collect(nowMs: _now);
      expect(_account(records, 'p2').secrets, {
        'account_token': 'admin',
        'kid/user_token': 'kid-user',
        'kid/srvA/token': 'kid-server',
      });
    });

    test('the local folders account is device-bound and not collected',
        () async {
      final a = _Device();
      await a.sources.putAccount(_localFolders());
      final records = await a.snapshot.collect(nowMs: _now);
      expect(records.whereType<AccountBackupRecord>(), isEmpty);
    });

    test('collecting twice with no change keeps updatedAt', () async {
      final a = _Device();
      await _addPlex(a);
      await a.settings.setDefaultQuality('1080p');
      await a.auth.write(
          PeerGroupSecret.storageKey,
          PeerGroupSecret.fromBytes(Uint8List.fromList(List.filled(32, 3)))
              .toBase64Url());

      final first = await a.snapshot.collect(nowMs: _now);
      final second = await a.snapshot.collect(nowMs: _now + 60000);

      expect(_account(second, 'p1').updatedAt, _now);
      expect(_setting(second, 'default_quality')!.updatedAt, _now);
      expect(second.whereType<GroupBackupRecord>().single.updatedAt, _now);
      expect(second, first);
    });

    test('a changed value or token gets a new updatedAt', () async {
      final a = _Device();
      await _addPlex(a);
      await a.settings.setDefaultQuality('1080p');
      await a.snapshot.collect(nowMs: _now);

      await a.settings.setDefaultQuality('720p');
      await a.auth.write('source/p1/owner/srv1/token', 'rotated');
      final second = await a.snapshot.collect(nowMs: _now + 1);

      expect(_setting(second, 'default_quality')!.updatedAt, _now + 1);
      expect(_account(second, 'p1').updatedAt, _now + 1);
    });

    test('a glass_material value is never collected', () async {
      final a = _Device();
      await a.settings.setGlassMaterial(GlassMaterial.values.last);
      await a.settings.setStatsOverlayEnabled(true);
      final records = await a.snapshot.collect(nowMs: _now);
      final keys = [
        for (final r in records.whereType<SettingBackupRecord>()) r.settingKey
      ];
      expect(keys, isNot(contains('glass_material')));
      expect(keys, isNot(contains('stats_overlay_enabled')));
    });

    test('an unset setting is skipped; a cleared one is collected as null',
        () async {
      final a = _Device();
      var records = await a.snapshot.collect(nowMs: _now);
      expect(_setting(records, 'interface_locale'), isNull);

      await a.settings.setLocaleCode('fr');
      await a.snapshot.collect(nowMs: _now + 1);
      await a.settings.setLocaleCode(null);
      records = await a.snapshot.collect(nowMs: _now + 2);
      final cleared = _setting(records, 'interface_locale')!;
      expect(cleared.value, isNull);
      expect(cleared.updatedAt, _now + 2);

      final b = _Device();
      await b.settings.setLocaleCode('de');
      await b.snapshot.apply(_viaWire(records),
          mode: BackupApplyMode.restore, fromDevice: 'A', nowMs: _now + 3);
      expect(await b.settings.getLocaleCode(), isNull);
    });

    test('a removed account becomes one stable tombstone', () async {
      final a = _Device();
      await _addPlex(a);
      await a.snapshot.collect(nowMs: _now);
      await a.sources.removeAccount('p1');

      final first = await a.snapshot.collect(nowMs: _now + 1);
      final second = await a.snapshot.collect(nowMs: _now + 2);
      final t1 = _account(first, 'p1');
      final t2 = _account(second, 'p1');
      expect(t1.deleted, isTrue);
      expect(t1.secrets, isEmpty);
      expect(t1.updatedAt, _now + 1);
      expect(t2.updatedAt, _now + 1);
    });

    test('watch and pin records carry their own updatedAt', () async {
      final a = _Device();
      await a.sync.recordProgress('tmdb:ep:1:1:2',
          positionSeconds: 30,
          durationSeconds: 100,
          watchedFraction: 0.9,
          nowMs: 111);
      await a.sync.setPin(
          groupKey: 'g', isShow: false, tmdbId: null, pinned: true, nowMs: 222);
      final records = await a.snapshot.collect(nowMs: _now);
      final w = records.whereType<WatchBackupRecord>().single;
      expect(w.key, 'tmdb:ep:1:1:2');
      expect(w.positionSeconds, 30);
      expect(w.updatedAt, 111);
      final p = records.whereType<PinBackupRecord>().single;
      expect(p.key, pinSyncKey(isShow: false, groupKey: 'g'));
      expect(p.updatedAt, 222);
    });

    test('the group record carries the secret and the node map', () async {
      final a = _Device();
      final secret =
          PeerGroupSecret.fromBytes(Uint8List.fromList(List.filled(32, 9)));
      await a.auth.write(PeerGroupSecret.storageKey, secret.toBase64Url());
      await a.meta.setNodeToSlot('node1', 'slotaaaa');
      final g = (await a.snapshot.collect(nowMs: _now))
          .whereType<GroupBackupRecord>()
          .single;
      expect(g.groupSecretB64, secret.toBase64Url());
      expect(g.nodeToSlot, {'node1': 'slotaaaa'});
    });

    test('no group secret, no group record', () async {
      final a = _Device();
      final records = await a.snapshot.collect(nowMs: _now);
      expect(records.whereType<GroupBackupRecord>(), isEmpty);
    });
  });

  group('live apply', () {
    test('adds no account and changes no setting, offers the account',
        () async {
      final a = _Device();
      await _addPlex(a);
      await a.settings.setDefaultQuality('1080p');
      final records = _viaWire(await a.snapshot.collect(nowMs: _now));

      final b = _Device();
      final result = await b.snapshot.apply(records,
          mode: BackupApplyMode.live,
          fromDevice: 'Living Room TV',
          nowMs: _now + 1);

      expect(result.accountsAdded, 0);
      expect(result.settingsApplied, 0);
      expect((await b.sources.load()).accounts, isEmpty);
      expect(b.dataKeys, isEmpty);
      expect(await b.settings.getDefaultQuality(), 'auto');
      final offer = result.newOffers.single;
      expect(offer.accountId, 'p1');
      expect(offer.fromDevice, 'Living Room TV');
      expect(offer.displayName, 'Night Harbor Plex');
      expect(offer.kind, 'plex');
      expect(offer.updatedAt, _now);
      expect(b.meta.pendingAccounts().single.accountId, 'p1');
    });

    test('an offer is new once; a dismissed version is not offered again',
        () async {
      final a = _Device();
      await _addPlex(a);
      final records = _viaWire(await a.snapshot.collect(nowMs: _now));
      final b = _Device();

      await b.snapshot.apply(records,
          mode: BackupApplyMode.live, fromDevice: 'A', nowMs: _now);
      final again = await b.snapshot.apply(records,
          mode: BackupApplyMode.live, fromDevice: 'A', nowMs: _now);
      expect(again.newOffers, isEmpty);

      await b.meta.dismiss('p1', _now);
      expect(b.meta.pendingAccounts(), isEmpty);
      final afterDismiss = await b.snapshot.apply(records,
          mode: BackupApplyMode.live, fromDevice: 'A', nowMs: _now);
      expect(afterDismiss.newOffers, isEmpty);
      expect(b.meta.pendingAccounts(), isEmpty);

      // A newer version of the account is offered again.
      await a.auth.write('source/p1/owner/srv1/token', 'rotated');
      final newer = _viaWire(await a.snapshot.collect(nowMs: _now + 9));
      final reoffer = await b.snapshot.apply(newer,
          mode: BackupApplyMode.live, fromDevice: 'A', nowMs: _now + 10);
      expect(reoffer.newOffers.single.updatedAt, _now + 9);
    });

    test('an account already stored is not offered', () async {
      final a = _Device();
      await _addPlex(a);
      final records = _viaWire(await a.snapshot.collect(nowMs: _now));
      final b = _Device();
      await _addPlex(b);
      final result = await b.snapshot.apply(records,
          mode: BackupApplyMode.live, fromDevice: 'A', nowMs: _now);
      expect(result.newOffers, isEmpty);
    });

    test('the group secret is not written live', () async {
      final a = _Device();
      await a.auth.write(
          PeerGroupSecret.storageKey,
          PeerGroupSecret.fromBytes(Uint8List.fromList(List.filled(32, 1)))
              .toBase64Url());
      final records = _viaWire(await a.snapshot.collect(nowMs: _now));
      final b = _Device();
      await b.snapshot.apply(records,
          mode: BackupApplyMode.live, fromDevice: 'A', nowMs: _now);
      expect(await b.auth.read(PeerGroupSecret.storageKey), isNull);
    });
  });

  group('restore apply', () {
    test('restore_keeps_existing_account', () async {
      final a = _Device();
      await _addPlex(a);
      final records = _viaWire(await a.snapshot.collect(nowMs: _now));

      final b = _Device();
      await b.auth.write('source/p1/account_token', 'local-admin');
      await b.auth.write('source/p1/owner/srv1/token', 'local-server');
      await b.sources.putAccount(_plex());

      final result = await b.snapshot.apply(records,
          mode: BackupApplyMode.restore, fromDevice: 'A', nowMs: _now);
      expect(result.accountsAdded, 0);
      expect(b.putAccountCalls, isEmpty);
      expect(await b.auth.read('source/p1/owner/srv1/token'), 'local-server');
      expect(await b.auth.read('source/p1/account_token'), 'local-admin');
    });

    test('account tombstones are never applied', () async {
      final b = _Device();
      await _addPlex(b);
      await b.snapshot.apply(const [
        AccountBackupRecord(
          key: 'account:p1',
          recordJson: {},
          secrets: {},
          updatedAt: _now,
          deleted: true,
        ),
      ], mode: BackupApplyMode.restore, fromDevice: 'A', nowMs: _now);
      expect((await b.sources.load()).accounts, hasLength(1));
      expect(await b.auth.read('source/p1/account_token'), 'plex-admin-token');
    });

    test('a secret key outside the account layout is not written', () async {
      final b = _Device();
      await b.snapshot.apply([
        AccountBackupRecord(
          key: 'account:p1',
          recordJson: _plex().toJson(),
          secrets: const {
            'account_token': 'ok',
            '../../peer_group/secret': 'evil',
            'owner/srv1/token': 'srv',
          },
          updatedAt: _now,
        ),
      ], mode: BackupApplyMode.restore, fromDevice: 'A', nowMs: _now);
      expect(b.dataKeys.toSet(),
          {'source/p1/account_token', 'source/p1/owner/srv1/token'});
    });

    test('a record whose JSON names another account is skipped', () async {
      final b = _Device();
      final result = await b.snapshot.apply([
        AccountBackupRecord(
          key: 'account:other',
          recordJson: _plex().toJson(),
          secrets: const {'account_token': 'x'},
          updatedAt: _now,
        ),
        const AccountBackupRecord(
          key: 'account:broken',
          recordJson: {'account': 'nope'},
          secrets: {},
          updatedAt: _now,
        ),
      ], mode: BackupApplyMode.restore, fromDevice: 'A', nowMs: _now);
      expect(result.accountsAdded, 0);
      expect(b.dataKeys, isEmpty);
      expect((await b.sources.load()).accounts, isEmpty);
    });

    test('settings outside the allowlist are ignored', () async {
      final b = _Device();
      final result = await b.snapshot.apply(const [
        SettingBackupRecord(
            key: 'setting:glass_material',
            settingKey: 'glass_material',
            value: 'clear',
            updatedAt: _now),
        SettingBackupRecord(
            key: 'setting:peer_group/secret',
            settingKey: 'peer_group/secret',
            value: 'x',
            updatedAt: _now),
      ], mode: BackupApplyMode.restore, fromDevice: 'A', nowMs: _now);
      expect(result.settingsApplied, 0);
      expect(b.dataKeys, isEmpty);
    });

    test('never writes the group secret', () async {
      final a = _Device();
      final secret =
          PeerGroupSecret.fromBytes(Uint8List.fromList(List.filled(32, 5)));
      await a.auth.write(PeerGroupSecret.storageKey, secret.toBase64Url());
      await a.meta.setNodeToSlot('nodeA', 'slotA');
      final records = _viaWire(await a.snapshot.collect(nowMs: _now));

      // A secret without the roster would leave the device in a group whose
      // members reject it: restore does not rejoin, pairing again does.
      final b = _Device();
      await b.snapshot.apply(records,
          mode: BackupApplyMode.restore, fromDevice: 'A', nowMs: _now);
      expect(await b.auth.read(PeerGroupSecret.storageKey), isNull);
      expect(b.meta.nodeToSlot(), isEmpty,
          reason: 'node claims are taken per slot by BackupSyncService');

      final c = _Device();
      const local = 'local-secret-kept';
      await c.auth.write(PeerGroupSecret.storageKey, local);
      await c.snapshot.apply(records,
          mode: BackupApplyMode.restore, fromDevice: 'A', nowMs: _now);
      expect(await c.auth.read(PeerGroupSecret.storageKey), local);
    });

    test('restoring an offered account clears its offer', () async {
      final a = _Device();
      await _addPlex(a);
      final records = _viaWire(await a.snapshot.collect(nowMs: _now));
      final b = _Device();
      await b.snapshot.apply(records,
          mode: BackupApplyMode.live, fromDevice: 'A', nowMs: _now);
      expect(b.meta.pendingAccounts(), hasLength(1));
      await b.snapshot.apply(records,
          mode: BackupApplyMode.restore, fromDevice: 'A', nowMs: _now);
      expect(b.meta.pendingAccounts(), isEmpty);
    });
  });

  group('share roots', () {
    const smbId = 's0123456789abcdef';
    const root = LibraryRoot(
        id: 'r0123456789ab',
        path: 'Movies',
        kind: FilesLibraryKind.movies,
        title: 'Movies');

    Future<void> addSmb(_Device d) async {
      await d.auth.write('source/$smbId/account_token', '{"password":"pw"}');
      await d.sources.putAccount(SourceAccountRecord(
        account: const ProviderAccount(
          id: smbId,
          kind: SourceKind.files,
          displayName: 'nas',
          storageNamespace: 'source/$smbId',
          activeProfileId: kOwnerProfileId,
        ),
        profiles: const [
          SourceProfile(
              id: kOwnerProfileId, accountId: smbId, name: 'O', isOwner: true),
        ],
        servers: const [
          SourceServer(
              id: smbId,
              accountId: smbId,
              profileId: kOwnerProfileId,
              name: 'nas'),
        ],
        addedAtMs: 5,
      ));
      d.roots[smbId] = [root];
    }

    test('collect includes an SMB account roots', () async {
      final a = _Device();
      await addSmb(a);
      final rec = _account(await a.snapshot.collect(nowMs: _now), smbId);
      expect(rec.recordJson['roots'], [root.toMap()]);
    });

    test('restore calls putRoots after the record, then collects stably',
        () async {
      final a = _Device();
      await addSmb(a);
      final records = _viaWire(await a.snapshot.collect(nowMs: _now));

      final b = _Device();
      final result = await b.snapshot.apply(records,
          mode: BackupApplyMode.restore, fromDevice: 'A', nowMs: _now + 1);
      expect(result.accountsAdded, 1);
      expect(b.putRootsCalls[smbId]!.single.toMap(), root.toMap());
      expect(await b.auth.read('source/$smbId/account_token'),
          '{"password":"pw"}');
      final again = await b.snapshot.collect(nowMs: _now + 9);
      expect(_account(again, smbId).updatedAt, _now);
    });

    test('an account whose roots failed is finished by the next apply',
        () async {
      final a = _Device();
      await addSmb(a);
      final records = _viaWire(await a.snapshot.collect(nowMs: _now));

      final b = _Device();
      b.failNextPutRoots = true;
      await expectLater(
          b.snapshot.apply(records,
              mode: BackupApplyMode.restore, fromDevice: 'A', nowMs: _now + 1),
          throwsStateError);
      expect(
          (await b.sources.load()).accounts.map((r) => r.account.id), [smbId]);
      // Not uploaded without its folders, where it would outrank A's.
      expect(
          (await b.snapshot.collect(nowMs: _now + 2))
              .whereType<AccountBackupRecord>(),
          isEmpty);

      // A live poll, not only a restore, finishes it.
      await b.snapshot.apply(records,
          mode: BackupApplyMode.live, fromDevice: 'A', nowMs: _now + 3);
      expect(b.putRootsCalls[smbId]!.single.toMap(), root.toMap());
      expect(b.meta.pendingAccounts(), isEmpty);
      final again = await b.snapshot.collect(nowMs: _now + 9);
      expect(_account(again, smbId).recordJson['roots'], [root.toMap()]);
      expect(_account(again, smbId).updatedAt, _now);
    });

    test('a root change re-stamps the account', () async {
      final a = _Device();
      await addSmb(a);
      await a.snapshot.collect(nowMs: _now);
      a.roots[smbId] = [
        root,
        const LibraryRoot(
            id: 'rfedcba987654',
            path: 'Shows',
            kind: FilesLibraryKind.series,
            title: 'Shows'),
      ];
      final again = await a.snapshot.collect(nowMs: _now + 1);
      expect(_account(again, smbId).updatedAt, _now + 1);
    });

    test('the local folders account is still excluded', () async {
      final a = _Device();
      await a.sources.putAccount(_localFolders());
      a.roots[kFilesLocalAccountId] = [root];
      final records = await a.snapshot.collect(nowMs: _now);
      expect(records.whereType<AccountBackupRecord>(), isEmpty);
    });

    test('a non-files account carries no roots', () async {
      final a = _Device();
      await _addPlex(a);
      a.roots['p1'] = [root];
      final rec = _account(await a.snapshot.collect(nowMs: _now), 'p1');
      expect(rec.recordJson.containsKey('roots'), isFalse);
    });
  });

  group('fingerprints', () {
    test('are an HMAC under a per-install key, stable across calls', () async {
      final a = _Device();
      await a.settings.setDefaultQuality('1080p');
      await a.snapshot.collect(nowMs: _now);
      final key = await a.auth.read(kBackupFingerprintKeyStorageKey);
      expect(key, isNotNull);
      expect(base64Url.decode(base64.normalize(key!)), hasLength(32));

      String stored() =>
          (jsonDecode(a.metaStorage.get('stamp:setting:default_quality')!)
              as Map)['fp'] as String;
      final first = stored();
      final bare = sha256
          .convert(utf8.encode(jsonEncode({'value': '1080p'})))
          .toString();
      expect(first, isNot(bare));
      expect(first, hasLength(64));

      await a.snapshot.collect(nowMs: _now + 1);
      expect(stored(), first);
      expect(await a.auth.read(kBackupFingerprintKeyStorageKey), key);
    });

    test('two installs fingerprint the same value differently', () async {
      final a = _Device();
      final b = _Device();
      for (final d in [a, b]) {
        await d.settings.setDefaultQuality('1080p');
        await d.snapshot.collect(nowMs: _now);
      }
      String fp(_Device d) =>
          (jsonDecode(d.metaStorage.get('stamp:setting:default_quality')!)
              as Map)['fp'] as String;
      expect(fp(a), isNot(fp(b)));
    });
  });

  group('BackupMetaStore', () {
    test('stamp keeps updatedAt while the fingerprint is unchanged', () async {
      final m = BackupMetaStore(InMemoryBackupMetaStorage());
      expect(await m.stamp('k', 'fp1', 10), 10);
      expect(await m.stamp('k', 'fp1', 20), 10);
      expect(await m.stamp('k', 'fp2', 30), 30);
      expect(m.hasStamp('k'), isTrue);
      expect(m.hasStamp('other'), isFalse);
    });

    test('merged seq per slot', () async {
      final m = BackupMetaStore(InMemoryBackupMetaStorage());
      expect(m.mergedSeq('s1'), 0);
      await m.setMergedSeq('s1', 4);
      expect(m.mergedSeq('s1'), 4);
      expect(m.mergedSeq('s2'), 0);
    });

    test('persists through a Hive box', () async {
      final dir = await Directory.systemTemp.createTemp('backup_meta_test');
      Hive.init(dir.path);
      try {
        final box = await Hive.openBox<String>(BackupMetaStore.boxName);
        final m = BackupMetaStore(HiveBackupMetaStorage(box));
        await m.stamp('setting:x', 'fp', 5);
        await m.setMergedSeq('slot', 3);
        await m.setNodeToSlot('n', 's');
        await m.putPending(const PendingAccountOffer(
          accountId: 'p1',
          kind: 'plex',
          displayName: 'Plex',
          fromDevice: 'Living Room TV',
          updatedAt: 9,
        ));
        await box.close();

        final reopened = BackupMetaStore(HiveBackupMetaStorage(
            await Hive.openBox<String>(BackupMetaStore.boxName)));
        expect(await reopened.stamp('setting:x', 'fp', 99), 5);
        expect(reopened.mergedSeq('slot'), 3);
        expect(reopened.nodeToSlot(), {'n': 's'});
        expect(reopened.pendingAccounts().single.fromDevice, 'Living Room TV');
      } finally {
        await Hive.close();
        await dir.delete(recursive: true);
      }
    });
  });
}
