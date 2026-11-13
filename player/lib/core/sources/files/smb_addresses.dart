/// Pure helpers for the address list of one SMB share: the hostname and the
/// IP literals it has been reached at, in preference order.
library;

import 'package:flutter/foundation.dart';

import '../connection/source_connection.dart' show isPrivateHost;
import '../source.dart' show ServerConnection;
import 'backend/file_system_backend.dart' show BackendUnreachable;
import 'files_account.dart'
    show SmbCredentials, kSmbDefaultPort, normalizeSmbUrl, smbTargetOf;
import 'smb_native.dart' show SmbNative, SmbTarget, kSmb1OnlyReason;

/// At most this many stored connections per SMB server.
const kSmbMaxConnections = 6;

/// Trimmed, lowercased, no trailing dot.
String normalizeSmbHost(String host) {
  var h = host.trim().toLowerCase();
  while (h.endsWith('.')) {
    h = h.substring(0, h.length - 1);
  }
  return h;
}

final _ipv4 = RegExp(r'^\d{1,3}(\.\d{1,3}){3}$');

/// An IPv4 dotted quad, or anything containing `:` (IPv6).
bool isIpLiteral(String host) => _ipv4.hasMatch(host) || host.contains(':');

/// The connection for [t], built through [normalizeSmbUrl] so the URI shape
/// exists once. [smbTargetOf] of its uri gives [t] back.
ServerConnection smbConnectionOf(SmbTarget t) {
  final host = normalizeSmbHost(t.host);
  final authority = host.contains(':') ? '[$host]' : host;
  final port = t.port == kSmbDefaultPort ? '' : ':${t.port}';
  final uri =
      Uri.parse('smb://$authority$port/${Uri.encodeComponent(t.share)}');
  return ServerConnection(
    uri: Uri.parse(normalizeSmbUrl(uri)),
    local: isPrivateHost(host),
  );
}

/// One connection per distinct normalized host, in the given order, capped.
List<ServerConnection> smbConnections({
  required String share,
  required int port,
  required List<String> hosts,
}) {
  final seen = <String>{};
  final out = <ServerConnection>[];
  for (final raw in hosts) {
    final host = normalizeSmbHost(raw);
    if (host.isEmpty || !seen.add(host)) continue;
    out.add(smbConnectionOf(SmbTarget(host: host, port: port, share: share)));
  }
  return capSmbConnections(out);
}

/// At most [kSmbMaxConnections]; over that, drops IP literals from the end
/// first, then hostnames from the end. The first entry (the address that
/// last answered) is never dropped.
List<ServerConnection> capSmbConnections(List<ServerConnection> all) =>
    capSmbAddresses(all, (c) => c.uri.host);

/// The rule behind [capSmbConnections], for any list whose entries have a
/// host, so the stored list and an in-memory one are capped the same way.
List<T> capSmbAddresses<T>(List<T> all, String Function(T) hostOf) {
  final out = [...all];
  for (var i = out.length - 1; i > 0 && out.length > kSmbMaxConnections; i--) {
    if (isIpLiteral(normalizeSmbHost(hostOf(out[i])))) out.removeAt(i);
  }
  if (out.length > kSmbMaxConnections) {
    out.removeRange(kSmbMaxConnections, out.length);
  }
  return out;
}

/// [reached] first, then [current] without it, then [discovered] not already
/// present, capped.
List<ServerConnection> promoteSmbConnection(
  List<ServerConnection> current,
  ServerConnection reached, {
  List<ServerConnection> discovered = const [],
}) {
  final out = [reached, ...current.where((c) => c.uri != reached.uri)];
  for (final d in discovered) {
    if (!out.any((c) => c.uri == d.uri)) out.add(d);
  }
  return capSmbConnections(out);
}

bool _validPort(int? port) => port != null && port >= 1 && port <= 65535;

/// A typed server address and port field, or null when they cannot be used.
/// An empty [port] means [kSmbDefaultPort]. An IPv6 literal loses its
/// brackets. [host] text with exactly one colon and no brackets is
/// `host:port` (`nas.local:4455`), and `[fd00::5]:4455` is the same for an
/// IPv6 literal; either inline port wins over [port]. More colons without
/// brackets are an IPv6 literal.
({String host, int port})? parseSmbAddress(String host, String port) {
  var h = host.trim();
  int? inlinePort;
  if (h.startsWith('[')) {
    final close = h.indexOf(']');
    if (close < 0) return null;
    final rest = h.substring(close + 1);
    if (rest.isNotEmpty) {
      if (!rest.startsWith(':')) return null;
      inlinePort = int.tryParse(rest.substring(1));
      if (!_validPort(inlinePort)) return null;
    }
    h = h.substring(1, close);
  } else if (':'.allMatches(h).length == 1) {
    final colon = h.indexOf(':');
    inlinePort = int.tryParse(h.substring(colon + 1));
    if (!_validPort(inlinePort)) return null;
    h = h.substring(0, colon);
  }
  if (h.isEmpty || h.contains(RegExp(r'[\s/]'))) return null;
  final text = port.trim();
  final fieldPort = text.isEmpty ? kSmbDefaultPort : int.tryParse(text);
  final p = inlinePort ?? fieldPort;
  if (!_validPort(p)) return null;
  return (host: h, port: p!);
}

/// Lists the shares at the first of [hosts] that can be reached, and
/// returns them with that host. Only an unreachable address moves on: a
/// refused login or an SMB1-only server would answer the same anywhere. The
/// last address's failure is rethrown.
Future<(List<String> shares, String host)> listSharesAtFirstReachable(
    SmbNative native,
    List<String> hosts,
    int port,
    SmbCredentials credentials) async {
  assert(hosts.isNotEmpty, 'at least one address to try');
  for (var i = 0;; i++) {
    final host = hosts[i];
    try {
      return (await native.listShares(host, port, credentials), host);
    } on BackendUnreachable catch (e) {
      if (i == hosts.length - 1 || e.message == kSmb1OnlyReason) rethrow;
      debugPrint('[Smb] $host unreachable, trying the next address: $e');
    }
  }
}

List<SmbTarget> smbTargetsOf(List<ServerConnection> connections) =>
    [for (final c in connections) smbTargetOf(c.uri)];
