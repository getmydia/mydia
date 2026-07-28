import 'dart:async';
import 'dart:io';

import 'package:bonsoir/bonsoir.dart';
import 'package:dart_cast/dart_cast.dart' as dc;
import 'package:flutter/foundation.dart';

/// The mDNS service type Chromecast and Google TV receivers advertise.
const chromecastServiceType = '_googlecast._tcp';

/// Build a `dart_cast` device from a resolved Bonsoir service map.
///
/// Kept top-level and pure so the mapping is unit-testable without a live
/// network or a platform channel.
///
/// The keys read here (`service.name`, `service.port`, `service.hostAddresses`,
/// `service.attributes`) match the default `prefix: 'service.'` that
/// `BonsoirService.toJson()` uses — see
/// `bonsoir_platform_interface/src/service/service.dart`.
dc.CastDevice? chromecastDeviceFromBonsoir(Map<String, dynamic> serviceJson) {
  final addresses = (serviceJson['service.hostAddresses'] as List?)
          ?.cast<String>() ??
      const <String>[];
  final port = serviceJson['service.port'] as int?;

  if (addresses.isEmpty || port == null) return null;

  final attributes = Map<String, String>.from(
    (serviceJson['service.attributes'] as Map?) ?? const {},
  );

  // Chromecast advertises a human-friendly name in the `fn` TXT record; the
  // service name is often the far less useful "Chromecast-<hex>".
  final name = attributes['fn'] ??
      serviceJson['service.name'] as String? ??
      'Chromecast';

  return dc.CastDevice(
    id: attributes['id'] ?? '${addresses.first}:$port',
    name: name,
    protocol: dc.CastProtocol.chromecast,
    address: InternetAddress(addresses.first),
    port: port,
    metadata: attributes,
  );
}

/// Chromecast discovery backed by `bonsoir`.
///
/// `dart_cast`'s own provider opens raw multicast sockets, which iOS refuses
/// without the `com.apple.developer.networking.multicast` entitlement. Bonsoir
/// goes through Apple's Bonjour framework instead, so declaring
/// `_googlecast._tcp` in `NSBonjourServices` is sufficient.
class BonsoirChromecastDiscovery implements dc.DeviceDiscoveryProvider {
  BonsoirDiscovery? _discovery;
  StreamController<List<dc.CastDevice>>? _controller;
  StreamSubscription<BonsoirDiscoveryEvent>? _events;
  final Map<String, dc.CastDevice> _found = {};

  @override
  dc.CastProtocol get protocol => dc.CastProtocol.chromecast;

  @override
  Stream<List<dc.CastDevice>> startDiscovery({
    Duration timeout = const Duration(seconds: 10),
  }) {
    stopDiscovery();

    final controller = StreamController<List<dc.CastDevice>>.broadcast();
    _controller = controller;

    unawaited(_run(controller));

    return controller.stream;
  }

  Future<void> _run(StreamController<List<dc.CastDevice>> controller) async {
    try {
      final discovery = BonsoirDiscovery(type: chromecastServiceType);
      _discovery = discovery;
      await discovery.initialize();

      _events = discovery.eventStream?.listen((event) {
        switch (event) {
          case BonsoirDiscoveryServiceFoundEvent():
            // `BonsoirService.resolve` (an extension method) dispatches a
            // platform-channel call via the discovery action's own
            // ServiceResolver; the resolved service surfaces later as a
            // BonsoirDiscoveryServiceResolvedEvent.
            unawaited(event.service.resolve(discovery.serviceResolver));
          case BonsoirDiscoveryServiceResolvedEvent():
            final device = chromecastDeviceFromBonsoir(event.service.toJson());
            if (device != null) {
              _found[device.id] = device;
              controller.add(_found.values.toList());
            }
          case BonsoirDiscoveryServiceLostEvent():
            final name = event.service.name;
            _found.removeWhere((_, device) => device.name == name);
            controller.add(_found.values.toList());
          default:
            break;
        }
      });

      await discovery.start();
    } catch (e) {
      debugPrint('[BonsoirChromecastDiscovery] Discovery failed: $e');
      controller.addError(
        dc.DiscoveryException('Chromecast discovery was refused', e),
      );
    }
  }

  @override
  void stopDiscovery() {
    _events?.cancel();
    _events = null;
    unawaited(_discovery?.stop());
    _discovery = null;
    _found.clear();
    _controller?.close();
    _controller = null;
  }

  @override
  void dispose() => stopDiscovery();
}
