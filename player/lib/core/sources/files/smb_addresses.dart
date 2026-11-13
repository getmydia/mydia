/// Pure helpers for the address list of one SMB share: the hostname and the
/// IP literals it has been reached at, in preference order.
library;

import '../connection/source_connection.dart' show isPrivateHost;
import '../source.dart' show ServerConnection;
import 'files_account.dart' show kSmbDefaultPort, normalizeSmbUrl, smbTargetOf;
import 'smb_native.dart' show SmbTarget;

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
/// first. A hostname is never dropped.
List<ServerConnection> capSmbConnections(List<ServerConnection> all) {
  final out = [...all];
  for (var i = out.length - 1; i >= 0 && out.length > kSmbMaxConnections; i--) {
    if (isIpLiteral(out[i].uri.host)) out.removeAt(i);
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

List<SmbTarget> smbTargetsOf(List<ServerConnection> connections) =>
    [for (final c in connections) smbTargetOf(c.uri)];
