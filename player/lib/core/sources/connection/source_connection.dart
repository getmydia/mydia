/// How a third-party source reaches its server. Every request and every
/// stream reads the base at call time, so a better connection found later
/// is used from the next request on.
library;

import 'package:flutter/foundation.dart';

import '../../../domain/sources/source_error.dart';
import '../media_source.dart';
import '../source.dart';

abstract interface class SourceConnection {
  ValueListenable<SourceConnectionStatus> get status;

  /// The base in use, or null while connecting or unreachable.
  Uri? get currentBase;

  /// The base to use now. Throws `SourceException.unreachable()` when
  /// nothing answers.
  Future<Uri> base();

  /// Looks again: on resume, on a network change, on a timer.
  Future<void> refresh();

  /// A request through [base] failed to connect.
  void reportFailure(Uri base);

  void dispose();
}

/// A server with exactly one address, such as a Stash URL.
class SingleConnection implements SourceConnection {
  SingleConnection({
    required ServerConnection connection,
    required Future<bool> Function(Uri base) probe,
  })  : _connection = connection,
        _probe = probe;

  final ServerConnection _connection;
  final Future<bool> Function(Uri base) _probe;
  final _status = ValueNotifier(SourceConnectionStatus.connecting);
  bool _up = false;
  Future<bool>? _checking;

  @override
  ValueListenable<SourceConnectionStatus> get status => _status;

  @override
  Uri? get currentBase => _up ? _connection.uri : null;

  @override
  Future<Uri> base() async {
    if (_up) return _connection.uri;
    if (!await _check()) throw const SourceException.unreachable();
    return _connection.uri;
  }

  @override
  Future<void> refresh() async {
    await _check();
  }

  @override
  void reportFailure(Uri base) {
    _up = false;
    _status.value = SourceConnectionStatus.connecting;
  }

  Future<bool> _check() => _checking ??= () async {
        bool up;
        try {
          up = await _probe(_connection.uri);
        } catch (_) {
          up = false;
        }
        _up = up;
        _status.value = !up
            ? SourceConnectionStatus.unreachable
            : _connection.local
                ? SourceConnectionStatus.local
                : SourceConnectionStatus.remote;
        _checking = null;
        return up;
      }();

  @override
  void dispose() => _status.dispose();
}

/// Whether [host] is on this network: RFC 1918, loopback, link-local,
/// unique-local IPv6, or an mDNS name.
bool isPrivateHost(String host) {
  final h = host.toLowerCase();
  if (h == 'localhost' || h.endsWith('.local') || h == '::1') return true;
  if (h.startsWith('fc') || h.startsWith('fd') || h.startsWith('fe80:')) {
    return h.contains(':');
  }
  final parts = h.split('.');
  if (parts.length != 4) return false;
  final octets = parts.map(int.tryParse).toList();
  if (octets.any((o) => o == null)) return false;
  final a = octets[0]!, b = octets[1]!;
  return a == 10 ||
      a == 127 ||
      (a == 172 && b >= 16 && b <= 31) ||
      (a == 192 && b == 168) ||
      (a == 169 && b == 254);
}
