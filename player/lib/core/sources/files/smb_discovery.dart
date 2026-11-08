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
  });

  /// The advertised instance name, for display.
  final String name;

  /// The resolved host, without a trailing dot.
  final String host;
  final int port;

  @override
  bool operator ==(Object other) =>
      other is DiscoveredSmbServer &&
      other.name == name &&
      other.host == host &&
      other.port == port;

  @override
  int get hashCode => Object.hash(name, host, port);

  @override
  String toString() => 'DiscoveredSmbServer($name, $host:$port)';
}

abstract interface class SmbDiscovery {
  /// Starts browsing on listen and stops on cancel. Emits the current list
  /// (de-duplicated by host, sorted by name) after each resolve or loss.
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
  final void Function(BonsoirService service) resolve;
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
    void Function(BonsoirService service)? resolve,
  }) : _open = (() async => _BrowseSession(
              events: events,
              start: start ?? () async {},
              stop: stop ?? () async {},
              resolve: resolve ?? (_) {},
            ));

  final Future<_BrowseSession> Function() _open;

  static Future<_BrowseSession> _openBonsoir() async {
    final discovery = BonsoirDiscovery(type: smbServiceType);
    await discovery.initialize();
    return _BrowseSession(
      events: discovery.eventStream ?? const Stream.empty(),
      start: discovery.start,
      stop: discovery.stop,
      resolve: (service) =>
          unawaited(service.resolve(discovery.serviceResolver)),
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
    final byName = <String, DiscoveredSmbServer>{};

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
          session?.resolve(event.service);
        case BonsoirDiscoveryServiceResolvedEvent():
          final server = _serverFrom(event.service);
          if (server == null) return;
          byName[event.service.name] = server;
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
    final host = _connectHost(service);
    if (host == null) return null;
    return DiscoveredSmbServer(
      name: service.name,
      host: host,
      port: service.port,
    );
  }

  /// The address to connect to. mDNS `.local` names do not resolve through
  /// Android's getaddrinfo (or Linux without nss-mdns), so prefer the first
  /// IPv4 address, then a global IPv6 one (link-local needs a scope id), and
  /// fall back to the hostname only when no usable address exists.
  static String? _connectHost(BonsoirService service) {
    final addresses = service.hostAddresses.map((a) => a.trim());
    for (final a in addresses) {
      if (_isIpv4(a)) return a;
    }
    for (final a in addresses) {
      if (a.contains(':') && !_isLinkLocalIpv6(a)) return a;
    }
    final raw = service.hostname;
    if (raw == null) return null;
    final host = raw.endsWith('.') ? raw.substring(0, raw.length - 1) : raw;
    return host.isEmpty ? null : host;
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

  /// De-duplicated by host (first name wins) and sorted by name.
  static List<DiscoveredSmbServer> _snapshot(
    Iterable<DiscoveredSmbServer> servers,
  ) {
    final sorted = servers.toList()..sort((a, b) => a.name.compareTo(b.name));
    final seen = <String>{};
    return [
      for (final s in sorted)
        if (seen.add(s.host)) s,
    ];
  }
}
