import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/p2p/media_proxy.dart';
import 'package:player/core/sources/files/backend/file_system_backend.dart';
import 'package:player/core/sources/files/files_account.dart';
import 'package:player/core/sources/files/smb_native.dart';
import 'package:player/native/smb.dart' as native;

import 'fake_smb_native.dart';

const _target = SmbTarget(host: 'nas', port: 445, share: 'media');
const _creds = SmbCredentials(user: 'u', password: 'p');

Future<Object?> _failWith(
  native.FfiSmbErrorKind kind, [
  String message = 'boom',
]) async {
  final smb = FfiSmbNative.forTest(
    () async => throw native.FfiSmbError(kind: kind, message: message),
  );
  try {
    await smb.probe(_target, _creds, '/');
  } catch (e) {
    return e;
  }
  return null;
}

void main() {
  group('FfiSmbNative error mapping', () {
    test('Unreachable', () async {
      final e = await _failWith(native.FfiSmbErrorKind.unreachable);
      expect(e, isA<BackendUnreachable>());
      expect((e! as BackendUnreachable).message, 'boom');
    });

    test('Unauthorized', () async {
      expect(await _failWith(native.FfiSmbErrorKind.unauthorized),
          isA<BackendUnauthorized>());
    });

    test('AccessDenied', () async {
      final e = await _failWith(native.FfiSmbErrorKind.accessDenied);
      expect(e, isA<BackendPermissionLost>());
      expect((e! as BackendPermissionLost).message, 'boom');
    });

    test('NotFound', () async {
      final e = await _failWith(native.FfiSmbErrorKind.notFound);
      expect(e, isA<BackendNotFound>());
      expect((e! as BackendNotFound).message, 'boom');
    });

    test('Smb1Only', () async {
      final e = await _failWith(native.FfiSmbErrorKind.smb1Only);
      expect(e, isA<BackendUnreachable>());
      expect((e! as BackendUnreachable).message, kSmb1OnlyReason);
    });

    test('Unsupported and Other', () async {
      for (final kind in [
        native.FfiSmbErrorKind.unsupported,
        native.FfiSmbErrorKind.other,
      ]) {
        final e = await _failWith(kind, 'why');
        expect(e, isA<BackendUnreachable>());
        expect((e! as BackendUnreachable).message, 'why');
      }
    });

    test('any other error, such as a Rust panic, is unreachable', () async {
      final smb = FfiSmbNative.forTest(
        () async => throw StateError('task panicked'),
      );
      Object? caught;
      try {
        await smb.probe(_target, _creds, '/');
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<BackendUnreachable>());
      expect((caught! as BackendUnreachable).message, contains('panicked'));
    });

    test('a success passes through', () async {
      final smb = FfiSmbNative.forTest(() async => null);
      await smb.probe(_target, _creds, '/');
    });
  });

  group('FfiSmbNative.heals', () {
    test('only non-healthy results are emitted', () async {
      final results = [
        native.FfiHeal.healthy,
        native.FfiHeal.reboundNewPort,
        native.FfiHeal.reboundSamePort,
      ];
      final smb = FfiSmbNative.forTest(() async => results.removeAt(0));
      final seen = <ProxyHeal>[];
      final sub = smb.heals.listen(seen.add);
      expect(await smb.healListener(), ProxyHeal.healthy);
      expect(await smb.healListener(), ProxyHeal.reboundNewPort);
      expect(await smb.healListener(), ProxyHeal.reboundSamePort);
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      expect(seen, [ProxyHeal.reboundNewPort, ProxyHeal.reboundSamePort]);
    });
  });

  group('SmbCredentials', () {
    test('round trips', () {
      const c = SmbCredentials(user: 'u', password: 'p', domain: 'HOME');
      final back = SmbCredentials.fromJson(c.toJson());
      expect(back.user, 'u');
      expect(back.password, 'p');
      expect(back.domain, 'HOME');
    });

    test('domain is optional', () {
      expect(SmbCredentials.fromJson(_creds.toJson()).domain, isNull);
    });

    test('fromJson rejects what is not credentials', () {
      expect(
          () => SmbCredentials.fromJson('{}'), throwsA(isA<FormatException>()));
    });
  });

  group('FakeSmbNative', () {
    test('lists, stats, records opens and closes, throws its failure',
        () async {
      final fake = FakeSmbNative()
        ..addFile('media', '/Films/a.mkv', size: 5)
        ..addDir('media', '/Empty');
      final root = await fake.list(_target, _creds, '/');
      expect(root.map((e) => e.name), unorderedEquals(['Films', 'Empty']));
      expect((await fake.stat(_target, _creds, '/Films/a.mkv'))?.size, 5);
      expect(await fake.stat(_target, _creds, '/nope'), isNull);
      expect(await fake.open('acc', _target, _creds, '/Films/a.mkv'),
          'http://127.0.0.1:1/smb/0');
      expect(fake.opens, [('acc', '/Films/a.mkv')]);
      await fake.closeAccount('acc');
      expect(fake.closedAccounts, ['acc']);
      fake.failure = const BackendUnauthorized();
      await expectLater(fake.probe(_target, _creds, '/'),
          throwsA(isA<BackendUnauthorized>()));
      fake.failure = null;
      final heals = <ProxyHeal>[];
      fake.heals.listen(heals.add);
      fake.emitHeal(ProxyHeal.reboundNewPort);
      await Future<void>.delayed(Duration.zero);
      expect(heals, [ProxyHeal.reboundNewPort]);
    });
  });
}
