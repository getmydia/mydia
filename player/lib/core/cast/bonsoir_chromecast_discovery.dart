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

  /// Maps the raw mDNS instance name (e.g. `"Chromecast-abc123"`) to the id
  /// we filed the device under in [_found].
  ///
  /// A lost event only ever carries `BonsoirService.name` — the raw instance
  /// name, never the `fn` TXT-record friendly name `chromecastDeviceFromBonsoir`
  /// prefers for display. Matching a lost event against `device.name` (the
  /// friendly name) therefore almost never hits; this side table lets removal
  /// key off the one thing every stage of a service's lifecycle shares.
  final Map<String, String> _idsByServiceName = {};

  final _failuresController = StreamController<dc.CastException>.broadcast();

  /// Discovery failures that never reach [startDiscovery]'s own stream.
  ///
  /// `dart_cast`'s `DiscoveryManager` subscribes to each provider with an
  /// `onError` that only logs (`discovery_manager.dart`) — it does not
  /// forward the error to `CastService.startDiscovery`'s combined stream. An
  /// iOS local-network denial would otherwise surface as a silently empty
  /// device list. `DartCastBackend` listens here instead and republishes onto
  /// `CastBackend.failureStream` as `CastFailureKind.discoveryDenied`.
  Stream<dc.CastException> get failures => _failuresController.stream;

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
    final discovery = BonsoirDiscovery(type: chromecastServiceType);
    _discovery = discovery;

    try {
      await discovery.initialize();
      // stopDiscovery() may have run while we were awaiting initialize() —
      // e.g. a second startDiscovery() call, or an explicit stop — in which
      // case `_discovery` no longer points at this instance. Proceeding
      // would set up an eventStream listener against a `controller` that is
      // already closed, and `controller.add(...)` on a closed
      // StreamController throws a StateError from inside an event callback,
      // outside any surrounding try — an unhandled async error.
      if (!identical(_discovery, discovery)) {
        _stopOrphan(discovery);
        return;
      }

      _events = discovery.eventStream?.listen((event) {
        if (!identical(_discovery, discovery)) return;
        final snapshot = applyBonsoirEvent(event, discovery.serviceResolver);
        if (snapshot != null && !controller.isClosed) {
          controller.add(snapshot);
        }
      });

      await discovery.start();
      if (!identical(_discovery, discovery)) {
        // Same race as above, but after start(): this discovery instance is
        // now an orphan nothing holds a reference to and which would
        // otherwise keep running natively forever.
        _stopOrphan(discovery);
      }
    } catch (e) {
      debugPrint('[BonsoirChromecastDiscovery] Discovery failed: $e');
      final error = dc.DiscoveryException('Chromecast discovery was refused', e);
      if (!controller.isClosed) controller.addError(error);
      // dispose() (e.g. via DartCastBackend.dispose -> CastService.dispose
      // -> DiscoveryManager.dispose -> provider.dispose()) can close
      // _failuresController while this catch block is still running —
      // adding to a closed StreamController throws, and this runs inside an
      // unawaited future, so that would become an unhandled StateError. The
      // same class of bug F5 was filed for.
      if (!_failuresController.isClosed) _failuresController.add(error);
    }
  }

  /// Applies one Bonsoir discovery event to the found-devices table.
  ///
  /// Returns the updated device snapshot when the visible set changed, or
  /// `null` when the event didn't affect it (nothing to emit). Kept separate
  /// from the platform-channel plumbing in [_run] and free of any
  /// `StreamController` dependency so the id-based add/remove logic — the
  /// exact thing that was broken before — is unit-testable with hand-built
  /// `BonsoirDiscoveryEvent`/`BonsoirService` values and no platform channel.
  @visibleForTesting
  List<dc.CastDevice>? applyBonsoirEvent(
    BonsoirDiscoveryEvent event,
    ServiceResolver resolver,
  ) {
    switch (event) {
      case BonsoirDiscoveryServiceFoundEvent():
        // `BonsoirService.resolve` (an extension method) dispatches a
        // platform-channel call via the discovery action's own
        // ServiceResolver; the resolved service surfaces later as a
        // BonsoirDiscoveryServiceResolvedEvent.
        unawaited(event.service.resolve(resolver));
        return null;

      case BonsoirDiscoveryServiceResolvedEvent():
        final device = chromecastDeviceFromBonsoir(event.service.toJson());
        if (device == null) return null;
        _idsByServiceName[event.service.name] = device.id;
        _found[device.id] = device;
        return _found.values.toList();

      case BonsoirDiscoveryServiceLostEvent():
        final id = _idsByServiceName.remove(event.service.name);
        if (id == null) return null;
        _found.remove(id);
        return _found.values.toList();

      default:
        return null;
    }
  }

  void _stopOrphan(BonsoirDiscovery discovery) {
    unawaited(discovery.stop().catchError((Object e) {
      debugPrint(
        '[BonsoirChromecastDiscovery] Ignoring stop error for orphaned discovery: $e',
      );
    }));
  }

  @override
  void stopDiscovery() {
    _events?.cancel();
    _events = null;
    // initialize() may still be in flight when this runs (e.g. the app is
    // backgrounded right after starting discovery) — stopping before it
    // resolves throws an unhandled PlatformException from native code.
    unawaited(_discovery?.stop().catchError((Object e) {
      debugPrint('[BonsoirChromecastDiscovery] Ignoring stop error: $e');
    }));
    _discovery = null;
    _found.clear();
    _idsByServiceName.clear();
    if (_controller?.isClosed == false) _controller?.close();
    _controller = null;
  }

  @override
  void dispose() {
    stopDiscovery();
    unawaited(_failuresController.close());
  }
}
