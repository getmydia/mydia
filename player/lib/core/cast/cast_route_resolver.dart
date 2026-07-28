import '../../domain/models/cast_device.dart';
import '../player/streaming_strategy.dart';
import 'cast_backend.dart';

/// Where the receiver fetches media bytes from.
enum CastRouteKind {
  /// Straight from the Mydia server. Playback survives the app quitting.
  directServer,

  /// From this app's LAN-bound proxy, pulling over p2p.
  localBridge,
}

/// A resolved plan for getting one file to one receiver.
class CastRoute {
  final String mediaUrl;
  final CastRouteKind kind;
  final CastMediaKind mediaKind;

  /// Whether sidecar subtitles can be served on this route.
  ///
  /// False on [CastRouteKind.localBridge]: `P2pService` exposes only pairing,
  /// GraphQL, and HLS request protocols, so arbitrary subtitle files cannot be
  /// proxied, and the server's HLS output carries no subtitle renditions.
  final bool subtitlesSupported;

  const CastRoute({
    required this.mediaUrl,
    required this.kind,
    required this.mediaKind,
    required this.subtitlesSupported,
  });
}

/// Chooses between the direct-server and LAN-bridge routes.
///
/// Direct is preferred: it avoids routing every byte through the sending
/// device and lets playback outlive the app. The bridge exists for when the
/// receiver cannot reach the server at all.
class CastRouteResolver {
  final bool isP2pMode;
  final String? serverUrl;
  final String? mediaToken;
  final String? lanBaseUrl;

  const CastRouteResolver({
    required this.isP2pMode,
    required this.serverUrl,
    required this.mediaToken,
    required this.lanBaseUrl,
  });

  /// Returns null when neither route is usable.
  CastRoute? resolve({
    required String fileId,
    required CastProtocolKind protocol,
    bool forceBridge = false,
    bool forceTranscode = false,
  }) {
    // Chromecast plays HLS natively, which gives seeking and adaptive
    // bitrate. DLNA renderers generally cannot, so they get progressive.
    final isChromecast = protocol == CastProtocolKind.chromecast;
    final mediaKind =
        isChromecast ? CastMediaKind.hls : CastMediaKind.progressive;

    // [forceTranscode] is the escalation after a receiver rejects the media
    // outright, which is nearly always an unsupported codec.
    final strategy = forceTranscode
        ? StreamingStrategy.transcode
        : isChromecast
            ? StreamingStrategy.hlsCopy
            : StreamingStrategy.directPlay;

    final useBridge = forceBridge || isP2pMode;

    if (useBridge) {
      final base = lanBaseUrl;
      if (base == null) return null;

      final url = isChromecast
          ? '$base/hls/$fileId/index.m3u8'
          : '$base/direct/$fileId/stream';

      return CastRoute(
        mediaUrl: url,
        kind: CastRouteKind.localBridge,
        mediaKind: mediaKind,
        subtitlesSupported: false,
      );
    }

    final server = serverUrl;
    if (server == null) return null;

    return CastRoute(
      mediaUrl: StreamingStrategyService.buildStreamUrl(
        serverUrl: server,
        fileId: fileId,
        strategy: strategy,
        mediaToken: mediaToken,
      ),
      kind: CastRouteKind.directServer,
      mediaKind: mediaKind,
      subtitlesSupported: true,
    );
  }

  /// Turn a subtitle path into a URL the receiver can fetch, or null when the
  /// route cannot serve subtitles at all.
  String? resolveSubtitleUrl(CastRoute route, String relativeOrAbsoluteUrl) {
    if (!route.subtitlesSupported) return null;

    if (relativeOrAbsoluteUrl.startsWith('http://') ||
        relativeOrAbsoluteUrl.startsWith('https://')) {
      return relativeOrAbsoluteUrl;
    }

    final server = serverUrl;
    if (server == null) return null;

    return '$server$relativeOrAbsoluteUrl';
  }
}
