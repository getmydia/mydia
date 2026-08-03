import 'dart:async';
import 'dart:io';

import 'package:dart_cast/dart_cast.dart' as dc;
import 'package:flutter/foundation.dart';

import '../../domain/models/cast_device.dart';
import '../player/platform_features.dart';
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

/// EHOSTUNREACH on Darwin.
///
/// The same number is `ENOPKG` on Linux, where EHOSTUNREACH is 113. That
/// collision is why [looksLikeLocalNetworkDenial] checks the platform before
/// it looks at the errno.
const int _ehostunreachDarwin = 65;

/// Whether [address] sits on a network the OS treats as local, and is
/// therefore subject to Apple's local-network permission gate.
///
/// Loopback is deliberately excluded: a receiver on loopback is nonsense, and
/// loopback traffic is never permission-gated. Carrier-grade NAT
/// (`100.64.0.0/10`) is excluded for the same kind of reason, being carrier
/// space rather than a home LAN.
bool isLocalNetworkAddress(InternetAddress address) {
  final raw = address.rawAddress;

  if (address.type == InternetAddressType.IPv4) {
    if (raw.length != 4) return false;
    if (raw[0] == 10) return true;
    if (raw[0] == 172 && raw[1] >= 16 && raw[1] <= 31) return true;
    if (raw[0] == 192 && raw[1] == 168) return true;
    // RFC 3927 link-local, what a receiver falls back to with no DHCP.
    if (raw[0] == 169 && raw[1] == 254) return true;
    return false;
  }

  if (address.type == InternetAddressType.IPv6) {
    if (raw.length != 16) return false;
    if (raw[0] == 0xfe && (raw[1] & 0xc0) == 0x80) return true; // fe80::/10
    if ((raw[0] & 0xfe) == 0xfc) return true; // fc00::/7
    return false;
  }

  return false;
}

/// Whether a raw `connect()` error looks like Apple's local-network permission
/// gate rather than a receiver that is genuinely absent.
///
/// This is a heuristic and is knowingly imperfect. macOS and iOS expose no
/// public API for reading local-network authorization state, and ICMP would
/// need raw sockets Dart cannot open unprivileged, so there is no way to
/// confirm the receiver is actually alive. A denied permission and an
/// unplugged Chromecast produce the same errno. The message this drives is
/// hedged for exactly that reason: it names the permission as a likely cause
/// without asserting it.
///
/// [applePlatform] is injected rather than read from `Platform.isMacOS` so
/// this stays testable for every platform on one machine, following
/// `PlatformFeatures.computeSupportsKeyboardShortcuts`.
bool looksLikeLocalNetworkDenial({
  required Object error,
  required InternetAddress? target,
  required bool applePlatform,
}) {
  // Must come first: see the note on [_ehostunreachDarwin].
  if (!applePlatform) return false;
  if (error is! SocketException) return false;
  if (error.osError?.errorCode != _ehostunreachDarwin) return false;
  if (target == null) return false;
  return isLocalNetworkAddress(target);
}

/// Maps a stream of raw discovery exceptions to the app's failure
/// vocabulary. Extracted from [DartCastBackend]'s constructor so the exact
/// composition wiring [BonsoirChromecastDiscovery.failures] into
/// [CastBackend.failureStream] is unit-testable without a real `CastService`.
@visibleForTesting
Stream<CastFailureKind> mapDiscoveryFailures(
    Stream<dc.CastException> failures) {
  return failures.map(failureKindFor);
}

/// Drops receiver "durations" that are not durations.
///
/// A Chromecast reports `duration: -1` for any stream whose length it cannot
/// determine, which is every HLS playlist Mydia serves: the server runs
/// FFmpeg without `-hls_playlist_type` on purpose (see
/// `ffmpeg_hls_transcoder.ex`) so playback can start before the whole file is
/// remuxed, which means no `#EXT-X-ENDLIST` and therefore no advertised
/// length. `dart_cast` only null-checks the field
/// (`chromecast_session.dart`'s `status.duration != null`), so the `-1`
/// arrives here verbatim.
///
/// This is the single point where that placeholder is stopped. Letting it
/// past made the cast scrub bar render `00:-1`, made the slider seek to
/// `fraction * -1s` — i.e. the start of the video — and made the skip-ahead
/// button clamp every target against a `-1s` "end", also landing at the
/// start. Zero is filtered for the same reason: it is the pre-first-status
/// placeholder, never a real runtime.
@visibleForTesting
Stream<Duration> sanitizeDurations(Stream<Duration> durations) {
  return durations.where((duration) => duration > Duration.zero);
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
    _discoveryFailureSub = mapDiscoveryFailures(_chromecastDiscovery.failures)
        .listen(_failures.add);
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

  /// Builds a backend over a caller-supplied `dart_cast` service.
  ///
  /// The only seam through which `connect`'s session handover can be
  /// exercised without two real receivers on the network — the default
  /// factory builds a live `dc.CastService` that would try to open sockets.
  @visibleForTesting
  factory DartCastBackend.withService(dc.CastService service) {
    return DartCastBackend._(service, BonsoirChromecastDiscovery());
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
    // The declaration is hoisted out of the try so the catch below can
    // inspect the address we tried to reach. The *assignment* stays inside:
    // `InternetAddress(host)` throws a synchronous ArgumentError on a
    // malformed persisted host, and that needs the same translation to
    // CastBackendException everything else in this method gets — otherwise
    // a corrupt stored session surfaces as a raw ArgumentError from
    // startCast (restoreSession happens to swallow arbitrary exceptions,
    // but startCast does not).
    dc.CastDevice? target;

    try {
      target = _discovered[device.id] ?? reconstructDartCastDevice(device);
      if (target == null) {
        throw const CastBackendException(
          'That device is no longer on the network.',
          CastFailureKind.unreachable,
        );
      }

      // Switching receivers must hand the previous one back: overwriting
      // `_session` leaked the old session and left that receiver playing our
      // media with nothing able to stop it.
      if (_session != null && _connectedDevice?.id != device.id) {
        await disconnect();
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
      // after 15s with no RECEIVER_STATUS), ArgumentError
      // (DlnaSession.fromDevice when the persisted metadata is missing a
      // control URL, or InternetAddress() on a malformed persisted host) and
      // SocketException on this path — none of those are a CastException, so
      // nothing here would otherwise be translated before reaching the UI.
      //
      // The SocketException case is worth separating out: on macOS 15+ a
      // denied local-network permission is indistinguishable from an
      // ordinary unreachable host except by errno, and reporting it as
      // `unknown` sent users to their router instead of to Settings.
      if (looksLikeLocalNetworkDenial(
        error: e,
        target: target?.address,
        applePlatform: PlatformFeatures.isMacOS || PlatformFeatures.isIOS,
      )) {
        throw CastBackendException(
          e.toString(),
          CastFailureKind.localNetworkDenied,
        );
      }

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
    _durationSub =
        sanitizeDurations(session.durationStream).listen(_durations.add);
  }

  /// Always null: `dart_cast` 0.7.x offers no way to ask a receiver what it is
  /// playing without first taking it over.
  ///
  /// `CastService.connect` is the only entry point to a session, and both
  /// concrete sessions act on connect — `ChromecastSession.connect` sends
  /// `LAUNCH CC1AD845`, which evicts whatever app the receiver is running.
  /// A read-only probe would need the CASTV2 `GET_STATUS` message on
  /// `receiver-0`, and the channel that speaks it
  /// (`src/protocols/chromecast/castv2_channel.dart`) is not part of the
  /// package's public API. DLNA is no better off: `DlnaSession` exposes
  /// `GetPositionInfo`/`GetTransportInfo` only through its private polling
  /// loop, and neither returns the current track URI.
  ///
  /// Returning null makes `CastSessionManager.restoreSession` discard the
  /// stored session, which is the behaviour the design asks for when the
  /// receiver's state is unknown. The seam stays because it is the one place
  /// a future backend — hand-written CASTV2, or a dart_cast release that
  /// exposes receiver status — plugs the reattach path back in.
  @override
  Future<String?> probeReceiverContentUrl(CastDevice device) async => null;

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
