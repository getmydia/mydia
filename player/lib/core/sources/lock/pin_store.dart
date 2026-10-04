/// The PIN that unlocks locked and hidden sources where the OS cannot
/// authenticate, and the backup where it can.
library;

import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/auth_storage.dart';

sealed class PinCheck {
  const PinCheck();
}

final class PinAccepted extends PinCheck {
  const PinAccepted();
}

final class PinRejected extends PinCheck {
  const PinRejected();
}

/// Too many wrong PINs: nothing is checked before [until].
final class PinBlocked extends PinCheck {
  const PinBlocked(this.until);
  final DateTime until;
}

class PinStore {
  PinStore(this._storage, {DateTime Function()? now, this.iterations = 100000})
      : _now = now ?? DateTime.now;

  static const _hashKey = 'app_lock/pin';
  static const _failuresKey = 'app_lock/pin_failures';
  static const _blockedUntilKey = 'app_lock/pin_blocked_until';
  static const _freeAttempts = 5;
  static const _firstDelay = Duration(seconds: 30);
  static final _pinPattern = RegExp(r'^\d{4,6}$');

  final AuthStorage _storage;
  final DateTime Function() _now;

  /// Stored with the hash, so a later change only affects new PINs.
  final int iterations;

  static bool isValidPin(String pin) => _pinPattern.hasMatch(pin);

  Future<bool> hasPin() async => await _storage.read(_hashKey) != null;

  Future<void> setPin(String pin) async {
    if (!isValidPin(pin)) {
      throw ArgumentError.value('<redacted>', 'pin', 'must be 4 to 6 digits');
    }
    final random = Random.secure();
    final salt = List<int>.generate(16, (_) => random.nextInt(256));
    final hash = await _derive(pin, salt, iterations);
    await _storage.write(
      _hashKey,
      'v1\$$iterations\$${base64Encode(salt)}\$${base64Encode(hash)}',
    );
    await _resetFailures();
  }

  Future<PinCheck> check(String pin) async {
    final blockedUntil = await _blockedUntil();
    if (blockedUntil != null && _now().isBefore(blockedUntil)) {
      return PinBlocked(blockedUntil);
    }
    if (await _matches(pin)) {
      await _resetFailures();
      return const PinAccepted();
    }
    final failures = int.parse(await _storage.read(_failuresKey) ?? '0') + 1;
    await _storage.write(_failuresKey, '$failures');
    if (failures < _freeAttempts) return const PinRejected();
    final until =
        _now().add(_firstDelay * pow(2, failures - _freeAttempts).toInt());
    await _storage.write(_blockedUntilKey, until.toUtc().toIso8601String());
    return PinBlocked(until);
  }

  Future<void> clear() async {
    await _storage.delete(_hashKey);
    await _resetFailures();
  }

  Future<bool> _matches(String pin) async {
    final stored = await _storage.read(_hashKey);
    final parts = stored?.split(r'$');
    if (parts == null || parts.length != 4 || parts[0] != 'v1') return false;
    final expected = base64Decode(parts[3]);
    final actual =
        await _derive(pin, base64Decode(parts[2]), int.parse(parts[1]));
    if (actual.length != expected.length) return false;
    var diff = 0;
    for (var i = 0; i < actual.length; i++) {
      diff |= actual[i] ^ expected[i];
    }
    return diff == 0;
  }

  Future<List<int>> _derive(String pin, List<int> salt, int rounds) async {
    final key = await Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: rounds,
      bits: 256,
    ).deriveKeyFromPassword(password: pin, nonce: salt);
    return key.extractBytes();
  }

  Future<DateTime?> _blockedUntil() async {
    final raw = await _storage.read(_blockedUntilKey);
    return raw == null ? null : DateTime.tryParse(raw);
  }

  Future<void> _resetFailures() async {
    await _storage.delete(_failuresKey);
    await _storage.delete(_blockedUntilKey);
  }
}

final pinStoreProvider =
    Provider<PinStore>((ref) => PinStore(getAuthStorage()));
