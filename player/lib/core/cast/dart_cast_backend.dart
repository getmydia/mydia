import 'dart:async';

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
/// This is the only file that imports `dart_cast`. Replacing the package means
/// rewriting this file and nothing else.
class DartCastBackend implements CastBackend {
  final dc.CastService _service;

  final _states = StreamController<CastPlaybackState>.broadcast();
  final _positions = StreamController<Duration>.broadcast();
  final _durations = StreamController<Duration>.broadcast();
  final _failures = StreamController<CastFailureKind>.broadcast();

  StreamSubscription<dc.SessionState>? _stateSub;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration>? _durationSub;

  dc.CastSession? _session;
  CastDevice? _connectedDevice;
  final Map<String, dc.CastDevice> _discovered = {};

  DartCastBackend._(this._service);

  factory DartCastBackend() {
    return DartCastBackend._(dc.CastService(
      discoveryProviders: [
        // Chromecast goes through Bonsoir's native Bonjour backend so iOS works
        // without the multicast entitlement. DLNA has no such option: SSDP is
        // raw multicast, which is why it is unavailable on iOS.
        BonsoirChromecastDiscovery(),
        dc.DlnaDiscoveryProvider(),
      ],
      sessionFactory: _createSession,
    ));
  }

  @override
  Stream<List<CastDevice>> startDiscovery({
    required CastCapabilities capabilities,
    Duration timeout = const Duration(seconds: 10),
  }) {
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
    final target = _discovered[device.id];
    if (target == null) {
      throw const CastBackendException(
        'That device is no longer on the network.',
        CastFailureKind.unreachable,
      );
    }

    try {
      final session = await _service.connect(target);
      _session = session;
      _connectedDevice = device;
      _listen(session);
    } on dc.CastException catch (e) {
      throw CastBackendException(e.toString(), _failureKindFor(e));
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
      throw CastBackendException(e.toString(), _failureKindFor(e));
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

  /// Translate `dart_cast` exceptions into the app's failure vocabulary, which
  /// is what drives the bridge-retry decision in `CastSessionManager`.
  static CastFailureKind _failureKindFor(dc.CastException e) {
    if (e is dc.DeviceUnreachableException) return CastFailureKind.unreachable;
    if (e is dc.ProxyUpstreamException) return CastFailureKind.unreachable;
    if (e is dc.MediaLoadFailedException) return CastFailureKind.mediaLoadFailed;
    if (e is dc.ConnectionLostException) return CastFailureKind.connectionLost;
    if (e is dc.DiscoveryException) return CastFailureKind.discoveryDenied;
    return CastFailureKind.unknown;
  }
}
