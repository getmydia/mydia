import 'dart:async';
import 'dart:io';

import 'package:dart_cast/dart_cast.dart' as dc;
import 'package:flutter/foundation.dart';

import '../../domain/models/cast_device.dart';
import 'bonsoir_chromecast_discovery.dart';
import 'cast_backend.dart';
import 'cast_capabilities.dart';

/// Convert a `dart_cast` device into the app's domain model.
CastDevice toDomainDevice(dc.CastDevice device) {
  return CastDevice(
    id: device.id,
    name: device.name,
    protocol: device.protocol == dc.CastProtocol.dlna
        ? CastProtocolKind.dlna
        : CastProtocolKind.chromecast,
    model: device.metadata['md'],
    host: device.address.address,
    port: device.port,
    metadata: device.metadata,
  );
}

/// Rebuild a `dart_cast` device from persisted app state.
///
/// `DartCastBackend.connect` normally resolves its target from the devices
/// this process's own discovery sweep saw. `CastSessionManager.restoreSession`
/// runs before any such sweep — right after a fresh app launch — so it can
/// only offer the domain `CastDevice` it persisted. This rebuilds a usable
/// `dart_cast` device from that alone.
///
/// Chromecast only needs [CastDevice.host]/[CastDevice.port]. DLNA
/// additionally needs the AVTransport/RenderingControl/ConnectionManager
/// control URLs `DlnaSession.fromDevice` reads back out of `metadata` — which
/// is why [CastDevice.metadata] is round-tripped through `toJson`/`fromJson`
/// rather than being discovery-sweep-only state.
///
/// Returns `null` when there isn't enough persisted information to proceed
/// (no host or port), in which case the caller must fall through to
/// "device no longer reachable" rather than guess.
dc.CastDevice? reconstructDartCastDevice(CastDevice device) {
  final host = device.host;
  final port = device.port;
  if (host == null || port == null) return null;

  return dc.CastDevice(
    id: device.id,
    name: device.name,
    protocol: device.protocol == CastProtocolKind.dlna
        ? dc.CastProtocol.dlna
        : dc.CastProtocol.chromecast,
    address: InternetAddress(host),
    port: port,
    metadata: device.metadata,
  );
}

/// Collapse `dart_cast`'s session lifecycle into the app's playback states.
CastPlaybackState playbackStateFrom(dc.SessionState state) {
  switch (state) {
    case dc.SessionState.playing:
      return CastPlaybackState.playing;
    case dc.SessionState.paused:
      return CastPlaybackState.paused;
    case dc.SessionState.buffering:
    case dc.SessionState.loading:
    case dc.SessionState.connecting:
      return CastPlaybackState.buffering;
    case dc.SessionState.idle:
    case dc.SessionState.connected:
    case dc.SessionState.disconnected:
      return CastPlaybackState.idle;
  }
}

/// Translate a `dart_cast` exception into the app's failure vocabulary,
/// which is what drives the bridge-retry decision in `CastSessionManager`.
///
/// Kept top-level, pure, and public (not the private static method it used to
/// be) so the mapping — the single highest-leverage untested function in
/// this file — can be pinned with unit tests independent of any live
/// session.
///
/// Only [dc.MediaLoadFailedException] (Chromecast) and [dc.ProtocolException]
/// (DLNA) are ever actually thrown by the paths this backend calls —
/// confirmed by reading `chromecast_session.dart` and `dlna_controller.dart`.
/// [dc.DeviceUnreachableException], [dc.ConnectionLostException] and
/// [dc.ProxyUpstreamException] are declared in `cast_exceptions.dart` but
/// constructed nowhere in the package; the `is` checks for them are kept
/// anyway in case a future dart_cast version starts throwing them — they are
/// harmless if unreachable today.
///
/// [dc.ProtocolException] is DLNA's SOAP-level failure (HTTP >= 400 or a
/// request timeout while sending SetAVTransportURI/Play/etc — see
/// `dlna_controller.dart`'s `sendAction`). That is DLNA's equivalent of a
/// receiver-side LOAD failure, so it maps to `mediaLoadFailed` for the same
/// reason Chromecast's `MediaLoadFailedException` does — including the fact
/// that on both protocols this single kind now covers two different root
/// causes: an unsupported codec, or the receiver being unable to reach the
/// media URL at all. `CastSessionManager._retryRouteFor` accounts for the
/// latter by trying the bridge route before escalating to a transcode.
CastFailureKind failureKindFor(dc.CastException e) {
  if (e is dc.DeviceUnreachableException) return CastFailureKind.unreachable;
  if (e is dc.ProxyUpstreamException) return CastFailureKind.unreachable;
  if (e is dc.MediaLoadFailedException) return CastFailureKind.mediaLoadFailed;
  if (e is dc.ProtocolException) return CastFailureKind.mediaLoadFailed;
  if (e is dc.ConnectionLostException) return CastFailureKind.connectionLost;
  if (e is dc.DiscoveryException) return CastFailureKind.discoveryDenied;
  return CastFailureKind.unknown;
}

/// Maps a stream of raw discovery exceptions to the app's failure
/// vocabulary. Extracted from [DartCastBackend]'s constructor so the exact
/// composition wiring [BonsoirChromecastDiscovery.failures] into
/// [CastBackend.failureStream] is unit-testable without a real `CastService`.
@visibleForTesting
Stream<CastFailureKind> mapDiscoveryFailures(Stream<dc.CastException> failures) {
  return failures.map(failureKindFor);
}

/// Builds the protocol-specific `dart_cast` session for a discovered device.
///
/// `dc.CastService` has no built-in notion of "the right session type for
/// this device" — it is handed a [dc.SessionFactory] and calls it once per
/// `connect()`. Chromecast and DLNA each have a concrete `CastSession`
/// subclass; AirPlay is intentionally unsupported here since neither
/// `CastCapabilities` nor our discovery providers ever surface it.
dc.CastSession _createSession(dc.CastDevice device) {
  return switch (device.protocol) {
    dc.CastProtocol.chromecast => dc.ChromecastSession(device: device),
    dc.CastProtocol.dlna => dc.DlnaSession.fromDevice(device),
    dc.CastProtocol.airplay => throw const CastBackendException(
        'AirPlay is not supported by this backend.',
        CastFailureKind.unknown,
      ),
  };
}

/// [CastBackend] implemented over the `dart_cast` package.
///
/// This file and `bonsoir_chromecast_discovery.dart` are the only two files
/// in the project that import `dart_cast` directly. Replacing the package
/// means rewriting both of those and nothing else.
class DartCastBackend implements CastBackend {
  final dc.CastService _service;
  final BonsoirChromecastDiscovery _chromecastDiscovery;

  final _states = StreamController<CastPlaybackState>.broadcast();
  final _positions = StreamController<Duration>.broadcast();
  final _durations = StreamController<Duration>.broadcast();
  final _failures = StreamController<CastFailureKind>.broadcast();

  StreamSubscription<dc.SessionState>? _stateSub;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration>? _durationSub;
  StreamSubscription<CastFailureKind>? _discoveryFailureSub;

  dc.CastSession? _session;
  CastDevice? _connectedDevice;
  final Map<String, dc.CastDevice> _discovered = {};

  DartCastBackend._(this._service, this._chromecastDiscovery) {
    // dart_cast's DiscoveryManager only logs a provider's stream errors —
    // it never forwards them (see discovery_manager.dart) — so a discovery
    // denial would otherwise surface as a silently empty device list rather
    // than reaching the UI. This is the only path that gets it there.
    _discoveryFailureSub =
        mapDiscoveryFailures(_chromecastDiscovery.failures).listen(_failures.add);
  }

  factory DartCastBackend() {
    final chromecastDiscovery = BonsoirChromecastDiscovery();
    return DartCastBackend._(
      dc.CastService(
        discoveryProviders: [
          // Chromecast goes through Bonsoir's native Bonjour backend so iOS
          // works without the multicast entitlement. DLNA has no such
          // option: SSDP is raw multicast, which is why it is unavailable
          // on iOS.
          chromecastDiscovery,
          dc.DlnaDiscoveryProvider(),
        ],
        sessionFactory: _createSession,
      ),
      chromecastDiscovery,
    );
  }

  @override
  Stream<List<CastDevice>> startDiscovery({
    required CastCapabilities capabilities,
    Duration timeout = const Duration(seconds: 10),
  }) {
    // Cleared per sweep so a device that has genuinely disappeared cannot be
    // connected to forever off a stale cache entry; the freshest sweep's
    // results are the source of truth for what `connect()` can resolve.
    _discovered.clear();

    final protocols = <dc.CastProtocol>{
      if (capabilities.chromecast) dc.CastProtocol.chromecast,
      if (capabilities.dlna) dc.CastProtocol.dlna,
    };

    if (protocols.isEmpty) return Stream.value(const []);

    return _service
        .startDiscovery(protocols: protocols, timeout: timeout)
        .map((devices) {
      for (final device in devices) {
        _discovered[device.id] = device;
      }
      return devices.map(toDomainDevice).toList();
    });
  }

  @override
  void stopDiscovery() => _service.stopDiscovery();

  @override
  Future<void> connect(CastDevice device) async {
    // Falls back to rebuilding the dart_cast device from persisted state
    // when this process never discovered it — the path
    // `CastSessionManager.restoreSession` takes right after a fresh app
    // launch, before any discovery sweep has run.
    //
    // reconstructDartCastDevice is called *inside* the try below, not out
    // here: `InternetAddress(host)` throws a synchronous ArgumentError on a
    // malformed persisted host, and that needs the same translation to
    // CastBackendException everything else in this method gets — otherwise
    // a corrupt stored session surfaces as a raw ArgumentError from
    // startCast (restoreSession happens to swallow arbitrary exceptions,
    // but startCast does not).
    try {
      final target =
          _discovered[device.id] ?? reconstructDartCastDevice(device);
      if (target == null) {
        throw const CastBackendException(
          'That device is no longer on the network.',
          CastFailureKind.unreachable,
        );
      }

      final session = await _service.connect(target);
      _session = session;
      _connectedDevice = device;
      _listen(session);
    } on CastBackendException {
      rethrow;
    } on dc.CastException catch (e) {
      throw CastBackendException(e.toString(), failureKindFor(e));
    } catch (e) {
      // dart_cast also throws raw TimeoutException (ChromecastSession.connect
      // after 15s with no RECEIVER_STATUS) and ArgumentError
      // (DlnaSession.fromDevice when the persisted metadata is missing a
      // control URL, or InternetAddress() on a malformed persisted host) on
      // this path — none of those are a CastException, so nothing here
      // would otherwise be translated before reaching the UI.
      throw CastBackendException(e.toString(), CastFailureKind.unknown);
    }
  }

  void _listen(dc.CastSession session) {
    _cancelSubscriptions();

    _stateSub = session.stateStream.listen((state) {
      _states.add(playbackStateFrom(state));

      // `disconnected` collapses to `idle` in the playback state, so the
      // distinct "receiver went away" signal is republished separately.
      if (state == dc.SessionState.disconnected && _session != null) {
        _failures.add(CastFailureKind.connectionLost);
      }
    });
    _positionSub = session.positionStream.listen(_positions.add);
    _durationSub = session.durationStream.listen(_durations.add);
  }

  @override
  Future<void> disconnect() async {
    _cancelSubscriptions();

    try {
      await _session?.disconnect();
    } catch (e) {
      debugPrint('[DartCastBackend] Ignoring disconnect error: $e');
    }

    _session?.dispose();
    _session = null;
    _connectedDevice = null;
  }

  @override
  Future<void> loadMedia(CastMediaRequest request) async {
    final session = _requireSession();

    try {
      await session.loadMedia(dc.CastMedia(
        url: request.url,
        type: request.kind == CastMediaKind.hls
            ? dc.CastMediaType.hls
            : dc.CastMediaType.mp4,
        title: request.title,
        // request.subtitle is a short display line (e.g. "S1E3"), not a
        // subtitle *track* — dc.CastMedia has no equivalent field, so it is
        // intentionally dropped here. Only request.subtitles (caption
        // tracks) maps onto dc.CastMedia.subtitles below.
        imageUrl: request.imageUrl,
        startPosition: request.startPosition,
        subtitles: request.subtitles
            .map((track) => dc.CastSubtitle(
                  url: track.url,
                  label: track.label,
                  language: track.language,
                  format: 'vtt',
                ))
            .toList(),
      ));
    } on dc.CastException catch (e) {
      throw CastBackendException(e.toString(), failureKindFor(e));
    } catch (e) {
      // See the matching catch in connect(): dart_cast can also throw a raw
      // StateError (e.g. ChromecastSession.loadMedia before connect()) that
      // isn't a CastException and would otherwise reach the UI unwrapped.
      throw CastBackendException(e.toString(), CastFailureKind.unknown);
    }
  }

  @override
  Future<void> play() => _requireSession().play();

  @override
  Future<void> pause() => _requireSession().pause();

  @override
  Future<void> stop() => _requireSession().stop();

  @override
  Future<void> seek(Duration position) => _requireSession().seek(position);

  @override
  Future<void> selectSubtitle(CastSubtitleTrack? track) {
    return _requireSession().setSubtitle(track == null
        ? null
        : dc.CastSubtitle(
            url: track.url,
            label: track.label,
            language: track.language,
            format: 'vtt',
          ));
  }

  @override
  Stream<CastPlaybackState> get stateStream => _states.stream;

  @override
  Stream<Duration> get positionStream => _positions.stream;

  @override
  Stream<Duration> get durationStream => _durations.stream;

  @override
  Stream<CastFailureKind> get failureStream => _failures.stream;

  @override
  CastDevice? get connectedDevice => _connectedDevice;

  @override
  Future<void> dispose() async {
    _cancelSubscriptions();
    await _discoveryFailureSub?.cancel();
    _session?.dispose();
    await _service.dispose();
    await _states.close();
    await _positions.close();
    await _durations.close();
    await _failures.close();
  }

  dc.CastSession _requireSession() {
    final session = _session;
    if (session == null) {
      throw const CastBackendException(
        'No active cast session.',
        CastFailureKind.connectionLost,
      );
    }
    return session;
  }

  void _cancelSubscriptions() {
    _stateSub?.cancel();
    _positionSub?.cancel();
    _durationSub?.cancel();
    _stateSub = null;
    _positionSub = null;
    _durationSub = null;
  }
}
