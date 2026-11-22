import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/backup/backup_gzip.dart';
import 'package:player/core/backup/backup_records.dart';

const _watch = WatchBackupRecord(
  key: 'tmdb:ep:1001:1:2',
  watched: false,
  positionSeconds: 120,
  durationSeconds: 2400,
  updatedAt: 1000,
);
const _pin = PinBackupRecord(
  key: 'pin:s:night-harbor',
  groupKey: 'night-harbor',
  isShow: true,
  tmdbId: 77,
  pinned: true,
  updatedAt: 1001,
);
const _account = AccountBackupRecord(
  key: 'account:acc1',
  recordJson: {
    'id': 'acc1',
    'kind': 'jellyfin',
    'extra': {'b': 1, 'a': 2},
  },
  secrets: {'token': 'super-secret-token'},
  updatedAt: 1002,
);
const _setting = SettingBackupRecord(
  key: 'setting:theme',
  settingKey: 'theme',
  value: 'dark',
  updatedAt: 1003,
);
const _group = GroupBackupRecord(
  key: 'group',
  groupSecretB64: 'c2VjcmV0',
  nodeToSlot: {'node1': 'slot1'},
  updatedAt: 1004,
);

Map<String, dynamic> _enc(BackupRecord r) =>
    jsonDecode(jsonEncode(r.toJson())) as Map<String, dynamic>;

List<int> _gz(Object json) => gzipEncode(utf8.encode(jsonEncode(json)));

void main() {
  test('payload round-trips one of each type', () {
    final p = const BackupPayload(
      deviceName: 'Living Room TV',
      platform: 'android',
      createdAt: 5,
      records: [_watch, _pin, _account, _setting, _group],
    );
    final d = BackupPayload.decode(p.encode());
    expect(d.deviceName, 'Living Room TV');
    expect(d.platform, 'android');
    expect(d.createdAt, 5);
    expect(d.records.map(_enc), p.records.map(_enc));
    expect(
      d.records.map((r) => r.runtimeType).toList(),
      p.records.map((r) => r.runtimeType).toList(),
    );
    final acc = d.records[2] as AccountBackupRecord;
    expect(acc.secrets['token'], 'super-secret-token');
  });

  test('tombstones and null settings round-trip', () {
    const s = SettingBackupRecord(
      key: 'setting:x',
      settingKey: 'x',
      value: null,
      updatedAt: 1,
      deleted: true,
    );
    final r = BackupRecord.fromJson(_enc(s))!;
    expect(r.deleted, isTrue);
    expect((r as SettingBackupRecord).value, isNull);
  });

  test('unknown type is dropped on decode, not fatal', () {
    final d = BackupPayload.decode(
      _gz({
        'v': 1,
        'deviceName': 'd',
        'platform': 'p',
        'createdAt': 1,
        'records': [
          {'type': 'hologram', 'key': 'k', 'updatedAt': 1, 'deleted': false},
          _enc(_watch),
        ],
      }),
    );
    expect(d.records, hasLength(1));
    expect(d.records.single, isA<WatchBackupRecord>());
  });

  test('movedTo_roundtrips_and_is_absent_when_null', () {
    const base = BackupPayload(
      deviceName: 'd',
      platform: 'p',
      createdAt: 1,
      records: [],
    );
    expect(BackupPayload.decode(base.encode()).movedTo, isNull);
    expect(
      jsonDecode(utf8.decode(gzipDecode(base.encode()))),
      isNot(contains('movedTo')),
    );
    const moved = BackupPayload(
      deviceName: 'd',
      platform: 'p',
      createdAt: 1,
      records: [],
      movedTo: 'icloud',
    );
    expect(BackupPayload.decode(moved.encode()).movedTo, 'icloud');
  });

  test('payload_with_unknown_top_level_field_decodes', () {
    final d = BackupPayload.decode(
      _gz({
        'v': 1,
        'deviceName': 'd',
        'platform': 'p',
        'createdAt': 1,
        'records': <Object>[],
        'somethingNew': {'a': 1},
      }),
    );
    expect(d.deviceName, 'd');
    expect(d.movedTo, isNull);
  });

  test('newer_version_throws_NewerBackupVersionException', () {
    expect(
      () => BackupPayload.decode(_gz({'v': 2, 'records': <Object>[]})),
      throwsA(isA<NewerBackupVersionException>()),
    );
    expect(
      () => BackupPayload.decode(_gz({'v': 0, 'records': <Object>[]})),
      throwsA(isNot(isA<NewerBackupVersionException>())),
    );
  });

  test('decode throws FormatException for bad input', () {
    expect(() => BackupPayload.decode([1, 2, 3]), throwsFormatException);
    expect(
      () => BackupPayload.decode(gzipEncode(utf8.encode('{nope'))),
      throwsFormatException,
    );
    expect(
      () => BackupPayload.decode(_gz({'v': 2, 'records': <Object>[]})),
      throwsFormatException,
    );
    expect(
      () =>
          BackupPayload.decode(_gz({'v': 1, 'deviceName': 3, 'records': 'x'})),
      throwsFormatException,
    );
    expect(() => BackupPayload.decode(_gz([1])), throwsFormatException);
    expect(
      () => BackupPayload.decode(
        _gz({
          'v': 1,
          'deviceName': 'd',
          'platform': 'p',
          'createdAt': 1,
          'records': [
            {'type': 'watch', 'key': 'k'},
          ],
        }),
      ),
      throwsFormatException,
    );
  });

  test('unknown-type record without key is skipped, not fatal', () {
    final d = BackupPayload.decode(
      _gz({
        'v': 1,
        'deviceName': 'd',
        'platform': 'p',
        'createdAt': 1,
        'records': [
          {'type': 'hologram', 'updatedAt': 'soon'},
          _enc(_watch),
        ],
      }),
    );
    expect(d.records.single, isA<WatchBackupRecord>());
  });

  test('account id derives from key; bad account key is a FormatException', () {
    expect(_account.accountId, 'acc1');
    expect(
      () => BackupPayload.decode(
        _gz({
          'v': 1,
          'deviceName': 'd',
          'platform': 'p',
          'createdAt': 1,
          'records': [
            {..._enc(_account), 'key': 'acc1'},
          ],
        }),
      ),
      throwsFormatException,
    );
  });

  test('toString never leaks secrets', () {
    expect(_account.toString(), isNot(contains('super-secret-token')));
  });

  group('lwwMerge', () {
    WatchBackupRecord w(int at, {bool deleted = false, int pos = 1}) =>
        WatchBackupRecord(
          key: 'k',
          watched: false,
          positionSeconds: pos,
          updatedAt: at,
          deleted: deleted,
        );

    test('picks newer', () {
      final m = lwwMerge([
        [w(1)],
        [w(2, pos: 9)],
      ]);
      expect((m.single as WatchBackupRecord).positionSeconds, 9);
    });

    test('tombstone wins a tie', () {
      final m = lwwMerge([
        [w(5, pos: 99)],
        [w(5, deleted: true, pos: 1)],
      ]);
      expect(m.single.deleted, isTrue);
    });

    test('full tie breaks on larger JSON, order independent', () {
      final a = w(5, pos: 1), b = w(5, pos: 2);
      final ab = lwwMerge([
        [a],
        [b],
      ]).map(_enc).toList();
      final ba = lwwMerge([
        [b],
        [a],
      ]).map(_enc).toList();
      expect(ab, ba);
    });

    test('different types never collide and output is order independent', () {
      final x = [_watch, _pin, _account];
      final y = [_setting, _group, _watch];
      final m1 = lwwMerge([x, y]).map(_enc).toList();
      final m2 = lwwMerge([y, x]).map(_enc).toList();
      expect(m1, m2);
      expect(m1, hasLength(5));
    });
  });

  test('20,000 watch records encode under 1 MB', () {
    final records = <BackupRecord>[
      for (var i = 0; i < 20000; i++)
        WatchBackupRecord(
          key: 'tmdb:ep:${100000 + i * 7}:${i % 12 + 1}:${i % 24 + 1}',
          watched: i % 3 == 0,
          positionSeconds: (i * 37) % 7200,
          durationSeconds: 1800 + (i * 13) % 5400,
          updatedAt: 1760000000000 + i * 86413,
        ),
    ];
    final bytes = BackupPayload(
      deviceName: 'Living Room TV',
      platform: 'android',
      createdAt: 1,
      records: records,
    ).encode();
    expect(bytes.length, lessThan(1024 * 1024));
  });
}
