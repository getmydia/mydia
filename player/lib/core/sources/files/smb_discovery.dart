/// mDNS discovery of SMB servers (`_smb._tcp`) for the SMB add screen.
library;

import 'dart:async';

import 'package:bonsoir/bonsoir.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The mDNS service type SMB servers advertise.
const smbServiceType = '_smb._tcp';

/// An SMB server found on the local network.
@immutable
class DiscoveredSmbServer {
  const DiscoveredSmbServer({
    required this.name,
    required this.host,
    required this.port,
    this.alternatives = const [],
    this.hostname,
  });

  /// The advertised instance name, for display.
  final String name;

  /// The advertised mDNS hostname, lowercased with no trailing dot, whether
  /// or not addresses were also advertised. Null when none was advertised.
  final String? hostname;

  /// The resolved host, without a trailing dot: the preferred address.
  final String host;
  final int port;

  /// Further advertised addresses, in order of preference, to try when
  /// [host] cannot be reached (a NAS often advertises a container bridge or
  /// a second interface first).
  final List<String> alternatives;

  /// [host], then [alternatives].
  List<String> get addresses => [host, ...alternatives];

  @override
  bool operator ==(Object other) =>
      other is DiscoveredSmbServer &&
      other.name == name &&
      other.host == host &&
      other.port == port &&
      other.hostname == hostname &&
      listEquals(other.alternatives, alternatives);

  @override
  int get hashCode =>
      Object.hash(name, host, port, hostname, Object.hashAll(alternatives));

  @override
  String toString() => 'DiscoveredSmbServer($name, $host:$port)';
}

abstract interface class SmbDiscovery {
  /// Starts browsing on listen and stops on cancel. Emits the current list
  /// (de-duplicated by addresses and port, sorted by name) after each resolve or
  /// loss.
  /// Browsing errors emit an empty list; they are never thrown.
  Stream<List<DiscoveredSmbServer>> browse();
}

final smbDiscoveryProvider =
    Provider<SmbDiscovery>((_) => BonsoirSmbDiscovery());

/// One browse: the event stream plus the calls that drive it.
class _BrowseSession {
  const _BrowseSession({
    required this.events,
    required this.start,
    required this.stop,
    required this.resolve,
  });

  final Stream<BonsoirDiscoveryEvent> events;
  final Future<void> Function() start;
  final Future<void> Function() stop;
  final Future<void> Function(BonsoirService service) resolve;
}

class BonsoirSmbDiscovery implements SmbDiscovery {
  BonsoirSmbDiscovery() : _open = _openBonsoir;

  /// Test seam: the platform pieces are replaced by an injected event stream
  /// and callbacks. Everything else is the production path.
  @visibleForTesting
  BonsoirSmbDiscovery.forTest(
    Stream<BonsoirDiscoveryEvent> events, {
    Future<void> Function()? start,
    Future<void> Function()? stop,
    Future<void> Function(BonsoirService service)? resolve,
  }) : _open = (() async => _BrowseSession(
              events: events,
              start: start ?? () async {},
              stop: stop ?? () async {},
              resolve: resolve ?? (_) async {},
            ));

  final Future<_BrowseSession> Function() _open;

  static Future<_BrowseSession> _openBonsoir() async {
    final discovery = BonsoirDiscovery(type: smbServiceType);
    await discovery.initialize();
    return _BrowseSession(
      events: discovery.eventStream ?? const Stream.empty(),
      start: discovery.start,
      stop: discovery.stop,
      resolve: (service) => service.resolve(discovery.serviceResolver),
    );
  }

  @override
  Stream<List<DiscoveredSmbServer>> browse() {
    // ignore: close_sinks
    late final StreamController<List<DiscoveredSmbServer>> controller;
    StreamSubscription<BonsoirDiscoveryEvent>? events;
    _BrowseSession? session;
    var cancelled = false;
    // Resolved servers keyed by instance name; a lost event only carries it.
    final byName = <String, _Resolved>{};

    void emit() {
      if (!controller.isClosed) controller.add(_snapshot(byName.values));
    }

    void fail(Object error) {
      debugPrint('[BonsoirSmbDiscovery] Discovery failed: $error');
      byName.clear();
      emit();
    }

    Future<void> stopSession(_BrowseSession s) async {
      try {
        await s.stop();
      } catch (e) {
        debugPrint('[BonsoirSmbDiscovery] Ignoring stop error: $e');
      }
    }

    void onEvent(BonsoirDiscoveryEvent event) {
      switch (event) {
        case BonsoirDiscoveryServiceFoundEvent():
          // A resolve fails asynchronously (Avahi refuses it, or the browse
          // stopped under it). That server just stays out of the list; the
          // others, and the browse, carry on.
          final s = session;
          if (s != null) {
            unawaited(Future.sync(() => s.resolve(event.service))
                .catchError((Object e) {
              debugPrint('[BonsoirSmbDiscovery] Could not resolve '
                  '${event.service.name}: $e');
            }));
          }
        case BonsoirDiscoveryServiceResolvedEvent():
          final server = _serverFrom(event.service);
          if (server == null) return;
          byName[event.service.name] = (
            server: server,
            endpoint: _endpoint(event.service, server),
          );
          emit();
        case BonsoirDiscoveryServiceLostEvent():
          if (byName.remove(event.service.name) != null) emit();
        default:
          break;
      }
    }

    Future<void> run() async {
      try {
        final opened = await _open();
        if (cancelled) {
          await stopSession(opened);
          return;
        }
        session = opened;
        events = opened.events.listen(onEvent, onError: fail);
        await opened.start();
        if (cancelled) await stopSession(opened);
      } catch (e) {
        fail(e);
      }
    }

    controller = StreamController<List<DiscoveredSmbServer>>(
      onListen: () => unawaited(run()),
      onCancel: () async {
        cancelled = true;
        await events?.cancel();
        events = null;
        final s = session;
        session = null;
        if (s != null) await stopSession(s);
      },
    );
    return controller.stream;
  }

  static DiscoveredSmbServer? _serverFrom(BonsoirService service) {
    final hosts = _connectHosts(service);
    if (hosts.isEmpty) return null;
    return DiscoveredSmbServer(
      name: service.name,
      host: hosts.first,
      port: service.port,
      alternatives: hosts.sublist(1),
      hostname: _normalizedHostname(service.hostname),
    );
  }

  static String? _normalizedHostname(String? raw) {
    if (raw == null) return null;
    var host = raw.trim().toLowerCase();
    if (host.endsWith('.')) host = host.substring(0, host.length - 1);
    return host.isEmpty ? null : host;
  }

  /// The addresses to connect to, best first. mDNS `.local` names do not
  /// resolve through Android's getaddrinfo (or Linux without nss-mdns), so
  /// IPv4 addresses come first, then global IPv6 ones (link-local needs a
  /// scope id), and the hostname only when no usable address exists. Every
  /// usable address is kept, since the first one advertised is not always
  /// reachable.
  static List<String> _connectHosts(BonsoirService service) {
    final addresses = service.hostAddresses.map((a) => a.trim()).toList();
    final usable = <String>{
      for (final a in addresses)
        if (_isIpv4(a)) a,
      for (final a in addresses)
        if (a.contains(':') && !_isLinkLocalIpv6(a)) a,
    };
    if (usable.isNotEmpty) return usable.toList();
    final raw = service.hostname;
    if (raw == null) return const [];
    final host = raw.endsWith('.') ? raw.substring(0, raw.length - 1) : raw;
    return host.isEmpty ? const [] : [host];
  }

  static bool _isIpv4(String a) =>
      RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(a);

  static bool _isLinkLocalIpv6(String a) {
    final lower = a.toLowerCase();
    return lower.startsWith('fe8') ||
        lower.startsWith('fe9') ||
        lower.startsWith('fea') ||
        lower.startsWith('feb') ||
        lower.contains('%');
  }

  /// What tells two services apart: every advertised address, including the
  /// link-local ones left out of the connection candidates, and the port. A
  /// service that advertised no address falls back to its hostname.
  static (String, int) _endpoint(
    BonsoirService service,
    DiscoveredSmbServer server,
  ) {
    final advertised = {
      for (final a in service.hostAddresses) a.trim(),
    }..remove('');
    final key = advertised.isEmpty ? server.addresses : advertised.toList();
    return ((key..sort()).join(' '), server.port);
  }

  /// De-duplicated by endpoint (see [_endpoint]; first name wins), and sorted
  /// by name. Two services on one host but different ports both stay, and so
  /// do two servers that share only some addresses (the same container
  /// bridge on two boxes, told apart only by their link-local IPv6).
  static List<DiscoveredSmbServer> _snapshot(Iterable<_Resolved> resolved) {
    final sorted = resolved.toList()
      ..sort((a, b) => a.server.name.compareTo(b.server.name));
    final seen = <(String, int)>{};
    return [
      for (final r in sorted)
        if (seen.add(r.endpoint)) r.server,
    ];
  }
}

/// A resolved server and the endpoint it is de-duplicated by.
typedef _Resolved = ({DiscoveredSmbServer server, (String, int) endpoint});
