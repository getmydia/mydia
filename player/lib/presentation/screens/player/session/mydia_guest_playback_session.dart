/// Playing an item from a guest Mydia server: the file's own bytes for
/// direct play, an HLS session the guest starts for copy and transcode, and
/// progress written back to the guest's own account of the viewer.
///
/// A guest reached by URL is played over plain HTTP with a bearer token. A
/// paired guest has no address to dial, so its bytes travel through its own
/// target on the local media proxy.
library;

import 'dart:convert';

import 'package:gql/ast.dart' show DocumentNode;

import '../../../../core/p2p/local_proxy_service.dart';
import '../../../../core/p2p/media_route.dart';
import '../../../../core/playback/playback_plan.dart';
import '../../../../core/playback/simple_playback_transport.dart';
import '../../../../core/player/periodic_progress_reporter.dart';
import '../../../../core/player/progress_reporter.dart';
import '../../../../core/sources/mydia/guest_proxy.dart';
import '../../../../core/sources/mydia/mydia_guest_client.dart';
import '../../../../core/sources/mydia/mydia_guest_credentials.dart';
import '../../../../core/sources/mydia/mydia_guest_source.dart';
import '../../../../core/sources/source_http.dart';
import '../../../../domain/sources/item.dart';
import '../../../../domain/sources/source_error.dart';
import '../../../../graphql/mutations/end_streaming_session.graphql.dart';
import '../../../../graphql/mutations/mark_watched.graphql.dart';
import '../../../../graphql/mutations/start_streaming_session.graphql.dart';
import '../../../../graphql/mutations/update_episode_progress.graphql.dart';
import '../../../../graphql/mutations/update_movie_progress.graphql.dart';
import '../../../../graphql/queries/streaming_candidates.graphql.dart';
import 'jellyfin_playback_session.dart' show jellyfinCandidates;
import 'playback_session_types.dart';
import 'source_playback_session.dart';

class MydiaGuestPlaybackSession extends SourcePlaybackSession {
  MydiaGuestPlaybackSession({
    required MydiaGuestSource source,
    required super.item,
    required super.fileId,
    required LocalProxyService Function() proxy,
    SourceHttp? http,
  })  : _guest = source,
        _proxy = proxy,
        _http = http ?? SourceHttp(),
        super(source: source);

  final MydiaGuestSource _guest;
  final LocalProxyService Function() _proxy;
  final SourceHttp _http;

  MydiaGuestClient get _client => _guest.client;

  Future<List<CandidateStrategy>>? _streaming;
  List<CandidateStrategy>? _offered;

  /// The screen that holds the proxy for this session, set by
  /// [prepareStreaming] so the resolver can take its target under it.
  Object? _owner;

  bool get _isEpisode => item.kind == ItemKind.episode;

  /// What the guest says it can serve for this item, fetched once. A failure
  /// is not cached.
  Future<List<CandidateStrategy>> _streamingCandidates() {
    final cached = _streaming;
    if (cached != null) return cached;
    final fresh = () async {
      final data = await _client.request(
        documentNodeQueryStreamingCandidates,
        {
          'contentType': _isEpisode ? 'episode' : 'movie',
          'id': item.externalId,
        },
      );
      final raw = (data['streamingCandidates']
              as Map<String, dynamic>?)?['candidates'] as List? ??
          const [];
      final list = [
        for (final c in raw.whereType<Map<String, dynamic>>())
          CandidateStrategy(
            strategy: c['strategy'] as String,
            mime: c['mime'] as String? ?? '',
            videoCodec: c['videoCodec'] as String?,
          ),
      ];
      _offered = list;
      return list;
    }();
    _streaming = fresh;
    fresh.then<void>((_) {}, onError: (Object _) {
      if (identical(_streaming, fresh)) _streaming = null;
    });
    return fresh;
  }

  @override
  Future<CandidatesFetch> candidates(CandidateScope scope) async {
    try {
      await _streamingCandidates();
    } on SourceException catch (e) {
      return (offer: null, serverRejected: e.kind == SourceErrorKind.notFound);
    } catch (_) {
      return (offer: null, serverRejected: false);
    }
    return super.candidates(scope);
  }

  @override
  Future<StreamingPreparation> prepareStreaming({
    required Object owner,
    required void Function(String message) onProgress,
    required bool Function() isCurrent,
  }) async {
    _owner = owner;
    try {
      await _client.credentials();
      await _streamingCandidates();
    } on SourceException catch (e) {
      return StreamingUnavailable(e.viewerMessage);
    }
    return super.prepareStreaming(
        owner: owner, onProgress: onProgress, isCurrent: isCurrent);
  }

  @override
  List<CandidateStrategy> candidatesFor(MediaVersion version) =>
      _offered ?? jellyfinCandidates(version, null);

  /// A p2p guest cannot serve sidecar subtitle files ([fetchText] refuses
  /// them), so it lists none rather than tracks that can never load.
  @override
  Future<PlaybackDetail?> detail() async {
    final base = await super.detail();
    if (base == null || base.serverSubtitleTracks == null) return base;
    final credentials = await _client.credentials();
    if (!credentials.isP2p) return base;
    return PlaybackDetail(
      savedPositionSeconds: base.savedPositionSeconds,
      savedDurationSeconds: base.savedDurationSeconds,
      lastWatchedAt: base.lastWatchedAt,
      runtimeMinutes: base.runtimeMinutes,
    );
  }

  @override
  Future<String> fetchText(String path) async {
    final credentials = await _client.credentials();
    final base = credentials.serverUrl;
    if (credentials.isP2p || base == null) {
      throw const SourceException.unsupported(
          'Subtitle files are not fetched over p2p yet.');
    }
    final response = await _http.send(
      'GET',
      Uri.parse('${base.replaceFirst(RegExp(r'/+$'), '')}$path'),
      headers: {'Authorization': 'Bearer ${credentials.accessToken}'},
    );
    return utf8.decode(response.bodyBytes);
  }

  @override
  ProgressReporter createProgress() => MydiaGuestProgressReporter(
        client: _client,
        itemId: item.externalId,
        isEpisode: _isEpisode,
      );

  @override
  StreamResolver createResolver(ItemDetail detail, MediaVersion version) =>
      MydiaGuestStreamResolver(
        client: _client,
        proxy: _proxy,
        owner: _owner,
        target: _guest.source.account.id,
      );

  @override
  StreamResolver createReceiverResolver(
    ItemDetail detail,
    MediaVersion version, {
    String? burnSubtitleStreamId,
  }) =>
      throw UnsupportedError('Guest Mydia servers do not cast.');
}

class MydiaGuestStreamResolver implements StreamResolver {
  MydiaGuestStreamResolver({
    required this.client,
    required this.proxy,
    required this.owner,
    required this.target,
  });

  final MydiaGuestClient client;
  final LocalProxyService Function() proxy;

  /// Holds the proxy target: the player screen, which releases it on exit.
  /// Null until `prepareStreaming` has named one.
  final Object? owner;

  /// The proxy target key, the guest's account id.
  final String target;

  /// The proxy base for a paired guest, starting its target on first use. A
  /// repeat start re-targets with the credentials as they are now, which
  /// picks up a refreshed token.
  Future<String> _proxyBase(MydiaGuestCredentials credentials) async {
    final holder = owner;
    if (holder == null) {
      // A hold keyed on anything but the screen could never be released.
      throw StateError('A p2p stream needs the screen that will release it.');
    }
    return guestProxyBase(proxy(), credentials, owner: holder, target: target);
  }

  Future<String> _startSession(
    String fileId,
    HlsPlan plan,
    Duration startAt,
  ) async {
    final seconds = startAt.inSeconds;
    final data = await client.request(
      documentNodeMutationStartStreamingSession,
      {
        'fileId': fileId,
        'strategy':
            plan.strategy == HlsStrategy.copy ? 'HLS_COPY' : 'TRANSCODE',
        if (plan.rung.maxBitrateKbps case final kbps?) 'maxBitrate': kbps,
        if (plan.rung.height case final height?) 'maxHeight': height,
        if (seconds > 0) 'startPosition': seconds,
        'playlistMode': 'FULL',
      },
    );
    final id = (data['startStreamingSession']
        as Map<String, dynamic>?)?['sessionId'] as String?;
    if (id == null) {
      throw const SourceException.server(
          'The server did not start a streaming session.');
    }
    return id;
  }

  @override
  Future<ResolvedStream> resolve(
    PlaybackPlan plan, {
    required String fileId,
    required Duration startAt,
  }) async {
    final credentials = await client.credentials();
    final serverUrl = credentials.serverUrl?.replaceFirst(RegExp(r'/+$'), '');
    final viaProxy = credentials.isP2p;
    if (!viaProxy && serverUrl == null) {
      throw const SourceException.unreachable();
    }
    final base = viaProxy ? await _proxyBase(credentials) : serverUrl!;
    switch (plan) {
      case DirectPlayPlan():
        return viaProxy
            ? ResolvedStream(
                url: MediaRoutes.directStream(base, fileId),
                headers: const {},
              )
            : ResolvedStream(
                url: '$base/api/v1/stream/file/$fileId?strategy=DIRECT_PLAY',
                headers: {'Authorization': 'Bearer ${credentials.accessToken}'},
              );
      case HlsPlan():
        final sessionId = await _startSession(fileId, plan, startAt);
        return ResolvedStream(
          url: viaProxy
              ? MediaRoutes.hls(base, sessionId)
              : '$base/api/v1/hls/$sessionId/index.m3u8',
          // The guest's HLS routes need the token too; the proxy adds its
          // own when the bytes travel over p2p.
          headers: viaProxy
              ? const {}
              : {'Authorization': 'Bearer ${credentials.accessToken}'},
          sessionId: sessionId,
        );
    }
  }

  @override
  Future<void> end(String sessionId) async {
    try {
      await client.request(
          documentNodeMutationEndStreamingSession, {'sessionId': sessionId});
    } catch (_) {
      // Best effort: the guest reaps idle sessions itself.
    }
  }
}

class MydiaGuestProgressReporter extends PeriodicProgressReporter {
  MydiaGuestProgressReporter({
    required this.client,
    required this.itemId,
    required this.isEpisode,
  });

  final MydiaGuestClient client;
  final String itemId;
  final bool isEpisode;

  Future<void> _send(DocumentNode document, Map<String, dynamic> vars) async {
    await client.request(document, vars);
  }

  Future<void> _position(int positionSeconds, int durationSeconds) => _send(
        isEpisode
            ? documentNodeMutationUpdateEpisodeProgress
            : documentNodeMutationUpdateMovieProgress,
        {
          isEpisode ? 'episodeId' : 'movieId': itemId,
          'positionSeconds': positionSeconds,
          'durationSeconds': durationSeconds,
        },
      );

  @override
  Future<void> sendProgress({
    required int positionSeconds,
    required int durationSeconds,
    required bool paused,
  }) =>
      _position(positionSeconds, durationSeconds);

  @override
  Future<void> sendWatched() => _send(
        isEpisode
            ? documentNodeMutationMarkEpisodeWatched
            : documentNodeMutationMarkMovieWatched,
        {isEpisode ? 'episodeId' : 'movieId': itemId},
      );

  @override
  Future<void> sendStopped({
    required int positionSeconds,
    required int durationSeconds,
  }) =>
      _position(positionSeconds, durationSeconds);
}
