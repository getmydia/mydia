import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/lock/pin_store.dart';

import '../../../test_utils/mock_auth_storage.dart';

void main() {
  late MockAuthStorage storage;
  late DateTime now;
  PinStore store() => PinStore(storage, now: () => now, iterations: 1000);

  setUp(() {
    storage = MockAuthStorage();
    now = DateTime.utc(2026, 10, 4, 12);
  });

  test('validates 4 to 6 digits', () {
    expect(PinStore.isValidPin('1234'), isTrue);
    expect(PinStore.isValidPin('123456'), isTrue);
    expect(PinStore.isValidPin('123'), isFalse);
    expect(PinStore.isValidPin('1234567'), isFalse);
    expect(PinStore.isValidPin('12a4'), isFalse);
    expect(() => store().setPin('12'), throwsArgumentError);
  });

  test('accepts the PIN it stored and never stores it in clear', () async {
    await store().setPin('4821');
    expect(await store().hasPin(), isTrue);
    expect(await storage.read('app_lock/pin'), isNot(contains('4821')));
    expect(await store().check('4821'), isA<PinAccepted>());
    expect(await store().check('4822'), isA<PinRejected>());
  });

  test('rejects everything when no PIN is set', () async {
    expect(await store().hasPin(), isFalse);
    expect(await store().check('0000'), isA<PinRejected>());
  });

  test('blocks after five failures, doubling, and survives a restart',
      () async {
    await store().setPin('4821');
    for (var i = 0; i < 4; i++) {
      expect(await store().check('0000'), isA<PinRejected>());
    }
    final fifth = await store().check('0000');
    expect(fifth, isA<PinBlocked>());
    expect((fifth as PinBlocked).until, now.add(const Duration(seconds: 30)));

    // A fresh PinStore reads the persisted block, even for the right PIN.
    expect(await store().check('4821'), isA<PinBlocked>());

    now = now.add(const Duration(seconds: 31));
    final sixth = await store().check('0000');
    expect((sixth as PinBlocked).until, now.add(const Duration(seconds: 60)));

    now = now.add(const Duration(seconds: 61));
    expect(await store().check('4821'), isA<PinAccepted>());
    expect(await storage.read('app_lock/pin_failures'), isNull);
  });

  test('clear deletes the PIN and the backoff', () async {
    await store().setPin('4821');
    await store().check('0000');
    await store().clear();
    expect(await store().hasPin(), isFalse);
    expect(await storage.read('app_lock/pin_failures'), isNull);
  });

  group('corrupt storage', () {
    test('a malformed hash is a rejection, not a crash', () async {
      for (final bad in [
        'v1\$x\$!!\$!!',
        'v1\$1000\$AAAA\$%%%',
        'v1\$1000\$AAAA',
        'garbage',
      ]) {
        await storage.write('app_lock/pin', bad);
        expect(await store().check('4821'), isA<PinRejected>(), reason: bad);
      }
    });

    test('a garbage failures counter counts as zero', () async {
      await store().setPin('4821');
      await storage.write('app_lock/pin_failures', 'nope');
      expect(await store().check('0000'), isA<PinRejected>());
      expect(await storage.read('app_lock/pin_failures'), '1');
    });

    test('an unparseable block fails closed', () async {
      await store().setPin('4821');
      await storage.write('app_lock/pin_blocked_until', 'not a date');
      final r = await store().check('4821');
      expect(r, isA<PinBlocked>());
      expect((r as PinBlocked).until, now.add(const Duration(seconds: 30)));
    });

    test('setPin clears a persisted block', () async {
      await store().setPin('4821');
      for (var i = 0; i < 5; i++) {
        await store().check('0000');
      }
      expect(await store().check('4821'), isA<PinBlocked>());
      await store().setPin('1357');
      expect(await store().check('1357'), isA<PinAccepted>());
    });

    test('the backoff exponent is capped', () async {
      await store().setPin('4821');
      await storage.write('app_lock/pin_failures', '500');
      final r = await store().check('0000') as PinBlocked;
      expect(r.until, now.add(const Duration(seconds: 30 * 1024)));
    });
  });
}
