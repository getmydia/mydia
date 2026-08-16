import '../../domain/models/cast_device.dart';
import '../player/streaming_strategy.dart';
import 'cast_backend.dart';
import 'cast_streaming_session_service.dart';

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

  /// Server-side HLS session backing this route, when it needed one.
  ///
  /// Every Chromecast route does, bridged or direct: both address HLS by
  /// session id, so one has to exist before the URL means anything, and only
  /// a session can carry a resume offset. Null on a progressive route, which
  /// is served straight from the file endpoint. The session manager ends it
  /// when the route is abandoned or casting stops.
  final String? hlsSessionId;

  /// Media token captured when the route was resolved, so every URL built
  /// from this route — media *and* sidecar subtitles — carries the same
  /// credential the receiver needs.
  final String? mediaToken;

  /// The real media position the stream itself begins at.
  ///
  /// Non-zero only on an HLS route resumed mid-item, where the offset is baked
  /// into FFmpeg's `-ss` because a live-style playlist cannot be seeked into.
  /// The receiver's position zero means this much into the media, which is
  /// what `CastSessionManager`'s `StreamTimeline` translates back.
  final Duration startOffset;

  /// Tracks already rewritten to URLs this route's receiver can fetch.
  ///
  /// Resolved here rather than at load time because the shape depends
  /// entirely on the route: an HLS route addresses subtitles by streaming
  /// session, the progressive one by media file. `CastSessionManager` reads
  /// this and never has to know which kind it got.
  ///
  /// Empty either because none were offered, or because this route cannot
  /// serve subtitles at all — the bridged DLNA route, which streams the file
  /// directly with no streaming session to address them by. There is no
  /// separate "supported" flag: the resolver enforces that invariant by
  /// omitting tracks here rather than by a flag a caller has to remember to
  /// check.
  final List<CastSubtitleTrack> subtitles;

  const CastRoute({
    required this.mediaUrl,
    required this.kind,
    required this.mediaKind,
    this.hlsSessionId,
    this.mediaToken,
    this.startOffset = Duration.zero,
    this.subtitles = const [],
  });
}

/// Chooses between the direct-server and LAN-bridge routes.
///
/// Direct is preferred: it avoids routing every byte through the sending
/// device and lets playback outlive the app. The bridge exists for when the
/// receiver cannot reach the server at all.
///
/// Everything the resolver needs that can *change* — the LAN base URL, the
/// media token — is read through a callback at [resolve] time rather than
/// captured at construction. A snapshot taken when the resolver is built is
/// necessarily taken before the decisions that produce those values (LAN
/// access being enabled, a token being fetched), which made the bridge route
/// unreachable and the direct route unauthenticated.
class CastRouteResolver {
  final bool isP2pMode;
  final String? serverUrl;

  /// Fetches (refreshing if needed) the media token for direct URLs.
  final Future<String?> Function() mediaToken;

  /// Reads the proxy's current LAN base URL. Returns null while the proxy is
  /// loopback-only, which the manager avoids by enabling LAN access before
  /// asking for a bridge route.
  final String? Function() lanBaseUrl;

  /// Starts the server-side HLS session a bridged Chromecast route needs.
  final CastStreamingSessionService streamingSessions;

  const CastRouteResolver({
    required this.isP2pMode,
    required this.serverUrl,
    required this.mediaToken,
    required this.lanBaseUrl,
    required this.streamingSessions,
  });

  /// How a receiver speaking [protocol] is fed media.
  ///
  /// Chromecast plays HLS natively, which gives seeking and adaptive bitrate.
  /// DLNA renderers generally cannot, so they get a progressive byte-range
  /// stream of the whole file.
  ///
  /// Deliberately one function rather than a rule repeated per call site:
  /// [resolve] decides the kind, and anything that later has to reason about
  /// the resulting stream — notably `shouldRestartCastForSeek`, which must
  /// never restart a progressive route — has to reach the same answer.
  static CastMediaKind mediaKindFor(CastProtocolKind protocol) =>
      protocol == CastProtocolKind.chromecast
          ? CastMediaKind.hls
          : CastMediaKind.progressive;

  /// Whether [resolve] with these flags would produce a bridge route.
  ///
  /// The manager asks first so it can enable LAN access *before* the bridge
  /// URL is needed, rather than after — the ordering bug that made the bridge
  /// impossible to select.
  bool usesBridge({bool forceBridge = false}) => forceBridge || isP2pMode;

  /// Returns null when neither route is usable.
  ///
  /// [startPosition] is where the user wants playback to resume. On an HLS
  /// route it is baked into the server-side session, because a live-style
  /// playlist cannot be seeked into; on a progressive one it is left to a
  /// plain receiver seek, which byte ranges support.
  Future<CastRoute?> resolve({
    required String fileId,
    required CastProtocolKind protocol,
    bool forceBridge = false,
    bool forceTranscode = false,
    Duration startPosition = Duration.zero,
    List<CastSubtitleTrack> subtitles = const [],
  }) async {
    final isChromecast = protocol == CastProtocolKind.chromecast;
    final mediaKind = mediaKindFor(protocol);

    if (usesBridge(forceBridge: forceBridge)) {
      final base = lanBaseUrl();
      if (base == null) return null;

      // The DLNA branch streams the file itself, which the proxy addresses by
      // file id and needs no session. Chromecast gets HLS, which the proxy
      // addresses by *streaming session* id — so one has to be started first,
      // exactly as local playback does before building its own proxy URL.
      if (!isChromecast) {
        return CastRoute(
          mediaUrl: '$base/direct/$fileId/stream',
          kind: CastRouteKind.localBridge,
          mediaKind: mediaKind,
        );
      }

      final session = await streamingSessions.start(
        fileId: fileId,
        transcode: forceTranscode,
        startPosition: startPosition,
      );

      return CastRoute(
        mediaUrl: '$base/hls/${session.sessionId}/index.m3u8',
        kind: CastRouteKind.localBridge,
        mediaKind: mediaKind,
        hlsSessionId: session.sessionId,
        startOffset: session.startOffset,
        subtitles: _sessionSubtitles(
          subtitles,
          base: '$base/hls/${session.sessionId}',
          token: null,
        ),
      );
    }

    final server = serverUrl;
    if (server == null) return null;

    final token = await mediaToken();

    if (isChromecast) {
      // Deliberately not `/api/v1/stream/file/...?strategy=HLS_COPY`. That
      // redirect starts a session with no offset argument and returns no
      // session id, so a resume position could never be honored and
      // `_adoptHlsSession` could never end what it started. The mutation
      // gives both. `/api/v1/hls/...` sits behind `media_api_auth`, whose
      // `MediaAuth` plug accepts `?token=`, which a receiver needs because it
      // cannot send an Authorization header.
      final session = await streamingSessions.start(
        fileId: fileId,
        transcode: forceTranscode,
        startPosition: startPosition,
      );

      return CastRoute(
        mediaUrl:
            '$server/api/v1/hls/${session.sessionId}/index.m3u8?token=$token',
        kind: CastRouteKind.directServer,
        mediaKind: mediaKind,
        mediaToken: token,
        hlsSessionId: session.sessionId,
        startOffset: session.startOffset,
        // Session-relative subtitle URLs (`/api/v1/hls/<session>/subs_<id>.vtt`)
        // require a server new enough to serve that path. Against an older
        // server this 404s and the receiver shows no subtitles at all — there
        // is no fallback and no version check here; that tradeoff was made
        // deliberately in favor of one uniform URL shape. It replaces the
        // previous media-file URL shape
        // (`/api/player/v1/subtitles/file/:fileId/:trackId?format=vtt`),
        // which an older server does still serve.
        subtitles: _sessionSubtitles(
          subtitles,
          base: '$server/api/v1/hls/${session.sessionId}',
          token: token,
        ),
      );
    }

    // Only a progressive receiver reaches here, so the file endpoint is only
    // ever asked for whole-file bytes. [forceTranscode] is the escalation
    // after a receiver rejects the media outright, which is nearly always an
    // unsupported codec.
    return CastRoute(
      mediaUrl: StreamingStrategyService.buildStreamUrl(
        serverUrl: server,
        fileId: fileId,
        strategy: forceTranscode
            ? StreamingStrategy.transcode
            : StreamingStrategy.directPlay,
        mediaToken: token,
      ),
      kind: CastRouteKind.directServer,
      mediaKind: mediaKind,
      mediaToken: token,
      subtitles: _progressiveSubtitles(subtitles, server: server, token: token),
    );
  }

  /// Turns session-relative subtitle names into URLs for this route.
  ///
  /// The filename convention (`subs_<trackId>.vtt`) is the server's, defined
  /// in `Mydia.Streaming.SessionSubtitles`. It lives here rather than in
  /// `MediaRoutes` because this resolver already builds its sibling HLS URLs
  /// inline, and splitting the two across files is how they drift apart.
  static List<CastSubtitleTrack> _sessionSubtitles(
    List<CastSubtitleTrack> tracks, {
    required String base,
    required String? token,
  }) =>
      tracks
          .map((track) => track.copyWith(
                url: _withToken('$base/subs_${track.trackId}.vtt', token),
              ))
          .toList();

  /// Rewrites the media-file subtitle URLs the progressive (DLNA) route keeps
  /// using, since it has no streaming session to address subtitles by.
  ///
  /// This is the one route that actually reads `track.url` rather than
  /// rewriting it from `trackId`, so it is also the one place the URL
  /// requirement applies: a track with no media-file URL (e.g. one just
  /// downloaded, never assigned one) can't be served progressively and is
  /// dropped here rather than reaching the receiver as a broken link.
  static List<CastSubtitleTrack> _progressiveSubtitles(
    List<CastSubtitleTrack> tracks, {
    required String server,
    required String? token,
  }) =>
      tracks
          .where((track) => track.url.isNotEmpty)
          .map((track) => track.copyWith(
                url: _withToken(_absoluteUrl(server, track.url), token),
              ))
          .toList();

  static String _absoluteUrl(String server, String urlOrPath) =>
      urlOrPath.startsWith('http://') || urlOrPath.startsWith('https://')
          ? urlOrPath
          : '$server$urlOrPath';

  static String _withToken(String url, String? token) {
    if (token == null || url.contains('token=')) return url;
    return '$url${url.contains('?') ? '&' : '?'}token=$token';
  }
}
